#lang racket/base

(require racket/format
         racket/list
         "core.rkt"
         "export-common.rkt")

(provide export-matlab-loft)

(define loft-decimal-places 6)
(struct wire-path (vertices edges closed?) #:transparent)

(define (loft-number who value)
  (~r (finite-flonum who value) #:precision `(= ,loft-decimal-places)))

(define (point->matlab who p)
  (format "[~a ~a ~a]"
          (loft-number who (point3-x p))
          (loft-number who (point3-y p))
          (loft-number who (point3-z p))))

(define (incident-edges v)
  (filter (lambda (edge)
            (or (= (vertex-id v) (vertex-id (wire-edge-start edge)))
                (= (vertex-id v) (vertex-id (wire-edge-end edge)))))
          (model-edges)))

(define (other-vertex edge v)
  (if (= (vertex-id v) (vertex-id (wire-edge-start edge)))
      (wire-edge-end edge)
      (wire-edge-start edge)))

(define (edge-member? edge edges)
  (for/or ([candidate (in-list edges)])
    (= (wire-edge-id edge) (wire-edge-id candidate))))

(define (component-edges seed)
  (let loop ([pending (list seed)] [seen (hash)] [result '()])
    (cond
      [(null? pending) (reverse result)]
      [else
       (define edge (car pending))
       (define edge-id (wire-edge-id edge))
       (if (hash-has-key? seen edge-id)
           (loop (cdr pending) seen result)
           (loop (append (cdr pending)
                         (incident-edges (wire-edge-start edge))
                         (incident-edges (wire-edge-end edge)))
                 (hash-set seen edge-id #t)
                 (cons edge result)))])))

(define (ordered-component-path component)
  (define vertices
    (remove-duplicates
     (append (map wire-edge-start component) (map wire-edge-end component))
     #:key vertex-id))
  (define (degree v)
    (count (lambda (edge) (edge-member? edge component)) (incident-edges v)))
  (define start
    (or (findf (lambda (v) (= 1 (degree v))) vertices)
        (wire-edge-start (car component))))
  (let loop ([current start] [used (hash)] [ordered-vertices (list start)] [ordered-edges '()])
    (define choices
      (filter (lambda (edge)
                (and (edge-member? edge component)
                     (not (hash-has-key? used (wire-edge-id edge)))))
              (incident-edges current)))
    (cond
      [(null? choices)
       (wire-path (reverse ordered-vertices) (reverse ordered-edges) #f)]
      [else
       (define edge (car choices))
       (define next (other-vertex edge current))
       (define next-used (hash-set used (wire-edge-id edge) #t))
       (define next-edges (cons edge ordered-edges))
       (if (= (vertex-id next) (vertex-id start))
           (wire-path (reverse ordered-vertices) (reverse next-edges) #t)
           (loop next next-used (cons next ordered-vertices) next-edges))])))

(define (model-wire-paths)
  (let loop ([remaining (model-edges)] [paths '()])
    (if (null? remaining)
        (reverse paths)
        (let* ([component (component-edges (car remaining))]
               [next (filter (lambda (edge) (not (edge-member? edge component)))
                             remaining)])
          (loop next (cons (ordered-component-path component) paths))))))

(define (vertex-half-width who v)
  (define edges (incident-edges v))
  (define diameters (map wire-edge-diameter edges))
  (unless (andmap (lambda (diameter) (= diameter (car diameters)))
                  (cdr diameters))
    (error who
           "loft MATLAB export requires equal wire diameters at vertex ~a; received ~e"
           (vertex-id v)
           diameters))
  (/ (car diameters) 2))

(define (path-feed-segment path)
  (or (for/first ([edge (in-list (wire-path-edges path))]
                  [index (in-naturals 1)]
                  #:when (wire-edge-feed? edge))
        index)
      0))

(define (validate-loft-model! who)
  (when (null? (model-edges)) (error who "cannot export an empty model"))
  (for ([v (in-list (model-vertices))])
    (vertex-half-width who v)
    (when (> (length (incident-edges v)) 2)
      (error who
             "loft MATLAB export does not yet support branch vertex ~a with degree ~a"
             (vertex-id v)
             (length (incident-edges v)))))
  (define feeds (filter wire-edge-feed? (model-edges)))
  (when (> (length feeds) 1)
    (error who "loft MATLAB export currently supports at most one feed; received ~a"
           (length feeds)))
  feeds)

(define (write-path out who name path)
  (fprintf out "~aCenters = [ ...\n" name)
  (for ([v (in-list (wire-path-vertices path))])
    (define p (vertex-point v))
    (fprintf out "    ~a ~a ~a; ...\n"
             (loft-number who (point3-x p))
             (loft-number who (point3-y p))
             (loft-number who (point3-z p))))
  (fprintf out "];\n~aHalfWidths = [ ...\n" name)
  (for ([v (in-list (wire-path-vertices path))])
    (fprintf out "    ~a; ...\n" (loft-number who (vertex-half-width who v))))
  (fprintf out "];\n"))

(define (edge-direction edge)
  (define a (vertex-point (wire-edge-start edge)))
  (define b (vertex-point (wire-edge-end edge)))
  (define length (edge-length edge))
  (point3 (/ (- (point3-x b) (point3-x a)) length)
          (/ (- (point3-y b) (point3-y a)) length)
          (/ (- (point3-z b) (point3-z a)) length)))

(define (edge-midpoint edge)
  (define a (vertex-point (wire-edge-start edge)))
  (define b (vertex-point (wire-edge-end edge)))
  (point3 (/ (+ (point3-x a) (point3-x b)) 2)
          (/ (+ (point3-y a) (point3-y b)) 2)
          (/ (+ (point3-z a) (point3-z b)) 2)))

(define (write-analysis out who has-feed?)
  (define minimum-wire-diameter
    (apply min (map wire-edge-diameter (model-edges))))
  (fprintf out "\n%% Analysis mesh and far-field controls\n")
  (fprintf out "%% Edit this frequency as needed; it is initialized from model-frequency.\n")
  (fprintf out "operatingFrequency = ~a; %% Hz\n"
           (coordinate-string who (* 1000000 (model-frequency))))
  (fprintf out "minimumWireDiameter = ~a; %% m\n"
           (coordinate-string who minimum-wire-diameter))
  (fprintf out "%% Resolve both electrical wavelength and the thinnest square conductor.\n")
  (fprintf out "analysisMeshMaxEdgeLength = min(299792458/(10*operatingFrequency), ...\n")
  (fprintf out "    5*minimumWireDiameter);\n")
  (fprintf out "fprintf(\"Analysis mesh MaxEdgeLength: %g m.\\n\",analysisMeshMaxEdgeLength);\n")
  (fprintf out "figure;\nmesh(antennaObject,MaxEdgeLength=analysisMeshMaxEdgeLength);\n")
  (fprintf out "\nfigure;\nshow(antennaObject);\n")
  (fprintf out "\n%% Far-field analysis\n")
  (if has-feed?
      (begin (fprintf out "figure;\n")
             (fprintf out "pattern(antennaObject,operatingFrequency,Type=\"directivity\");\n"))
      (fprintf out "%% Add a feed before requesting a radiation pattern.\n")))

(define (write-helper-functions out)
  (display #<<MATLAB

function [points,triangles] = makeLoftedSquarePath(centers,halfWidths,isClosed,feedSegment)
    centerCount=size(centers,1);
    segmentCount=centerCount-1+double(isClosed);
    directions=zeros(segmentCount,3); segmentLengths=zeros(segmentCount,1);
    for segment=1:segmentCount
        next=segment+1; if next>centerCount; next=1; end
        delta=centers(next,:)-centers(segment,:);
        segmentLengths(segment)=norm(delta); directions(segment,:)=delta/segmentLengths(segment);
    end
    normals=zeros(segmentCount,3);
    [~,axisIndex]=min(abs(directions(1,:))); reference=zeros(1,3); reference(axisIndex)=1;
    normals(1,:)=unit(cross(directions(1,:),reference));
    for segment=2:segmentCount
        normals(segment,:)=transportNormal(normals(segment-1,:),directions(segment-1,:),directions(segment,:));
    end
    binormals=cross(directions,normals,2);
    startRings=cell(segmentCount,1); endRings=cell(segmentCount,1);
    points=zeros(0,3); triangles=zeros(0,3);
    for vertex=1:centerCount
        if ~isClosed && vertex==1
            [points,startRings{1}]=appendRing(points,centers(1,:),halfWidths(1),normals(1,:),binormals(1,:));
            continue
        elseif ~isClosed && vertex==centerCount
            [points,endRings{segmentCount}]=appendRing(points,centers(end,:),halfWidths(end),normals(end,:),binormals(end,:));
            continue
        end
        previous=vertex-1; if previous<1; previous=segmentCount; end
        following=vertex; if following>segmentCount; following=1; end
        cosine=max(-1,min(1,dot(directions(previous,:),directions(following,:))));
        turnAngle=acos(cosine);
        if turnAngle < 1e-8
            [points,ring]=appendRing(points,centers(vertex,:),halfWidths(vertex),normals(following,:),binormals(following,:));
            endRings{previous}=ring; startRings{following}=ring;
        else
            if pi-turnAngle < 1e-6; error('antenna-turtle:LoftReversal','Loft path contains a 180-degree reversal.'); end
            setback=sqrt(2)*halfWidths(vertex)*tan(turnAngle/2);
            if setback >= 0.45*min(segmentLengths(previous),segmentLengths(following))
                error('antenna-turtle:LoftSetback','A bend is too sharp for its adjacent segment lengths.');
            end
            incomingCenter=centers(vertex,:)-setback*directions(previous,:);
            outgoingCenter=centers(vertex,:)+setback*directions(following,:);
            [points,incomingRing]=appendRing(points,incomingCenter,halfWidths(vertex),normals(previous,:),binormals(previous,:));
            [points,outgoingRing]=appendRing(points,outgoingCenter,halfWidths(vertex),normals(following,:),binormals(following,:));
            mappedOutgoingRing=bestCyclicMapping(points,incomingRing,outgoingRing);
            %% Keep the following segment in its canonical frame order.  The
            %% cyclic mapping is local to this bend; propagating it would twist
            %% the entire following tube before its next canonical end ring.
            endRings{previous}=incomingRing; startRings{following}=outgoingRing;
            triangles=appendTubeFaces(triangles,incomingRing,mappedOutgoingRing);
        end
    end
    for segment=1:segmentCount
        if feedSegment==segment
            next=segment+1; if next>centerCount; next=1; end
            midpoint=(centers(segment,:)+centers(next,:))/2;
            halfWidth=(halfWidths(segment)+halfWidths(next))/2;
            [points,feedRing]=appendRing(points,midpoint,halfWidth,normals(segment,:),binormals(segment,:));
            triangles=appendTubeFaces(triangles,startRings{segment},feedRing);
            triangles=appendTubeFaces(triangles,feedRing,endRings{segment});
        else
            triangles=appendTubeFaces(triangles,startRings{segment},endRings{segment});
        end
    end
    if ~isClosed
        startCenter=size(points,1)+1; endCenter=startCenter+1;
        points=[points;centers(1,:);centers(end,:)];
        triangles=appendCap(triangles,startCenter,startRings{1},true);
        triangles=appendCap(triangles,endCenter,endRings{end},false);
    end
    points=round(points,6);
end

function [points,ids]=appendRing(points,center,halfWidth,normal,binormal)
    offsets=[-1 -1;1 -1;1 1;-1 1];
    ringPoints=center+halfWidth*(offsets(:,1).*normal+offsets(:,2).*binormal);
    ids=size(points,1)+(1:4); points=[points;ringPoints];
end

function mapped=bestCyclicMapping(points,first,second)
    best=inf; mapped=second;
    for shift=0:3
        candidate=circshift(second,-shift);
        cost=sum(vecnorm(points(first,:)-points(candidate,:),2,2).^2);
        if cost<best; best=cost; mapped=candidate; end
    end
end

function triangles=appendTubeFaces(triangles,first,second)
    for side=1:4
        next=mod(side,4)+1;
        triangles(end+1,:)=[first(side) first(next) second(next)];
        triangles(end+1,:)=[first(side) second(next) second(side)];
    end
end

function triangles=appendCap(triangles,center,ring,reverse)
    for side=1:4
        next=mod(side,4)+1;
        if reverse; triangles(end+1,:)=[center ring(next) ring(side)];
        else; triangles(end+1,:)=[center ring(side) ring(next)]; end
    end
end

function result=transportNormal(previousNormal,previousTangent,tangent)
    rotationAxis=cross(previousTangent,tangent); sine=norm(rotationAxis); cosine=dot(previousTangent,tangent);
    if sine<1e-12; result=previousNormal;
    else
        axis=rotationAxis/sine; angle=atan2(sine,cosine);
        result=previousNormal*cos(angle)+cross(axis,previousNormal)*sin(angle)+axis*dot(axis,previousNormal)*(1-cos(angle));
    end
    result=unit(result-dot(result,tangent)*tangent);
end

function result=unit(vector)
    magnitude=norm(vector); if magnitude<1e-12; error('antenna-turtle:DegenerateLoft','Degenerate loft direction.'); end
    result=vector/magnitude;
end
MATLAB
           out))

(define (export-matlab-loft path)
  (validate-model!)
  (define who 'export-matlab-loft)
  (define feeds (validate-loft-model! who))
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (out)
      (fprintf out "%% ~a\n" (model-title))
      (fprintf out "%% Experimental conformal square-loft export generated by antenna-turtle.\n")
      (fprintf out "allPoints=zeros(0,3); allTriangles=zeros(0,3);\n")
      (for ([path (in-list (model-wire-paths))] [index (in-naturals 1)])
        (define name (format "loftPath~a" index))
        (write-path out who name path)
        (fprintf out "[pathPoints,pathTriangles]=makeLoftedSquarePath( ...\n")
        (fprintf out "    ~aCenters,~aHalfWidths,~a,~a);\n"
                 name name (if (wire-path-closed? path) "true" "false")
                 (path-feed-segment path))
        (fprintf out "pathTriangles=pathTriangles+size(allPoints,1);\n")
        (fprintf out "allPoints=[allPoints;pathPoints]; allTriangles=[allTriangles;pathTriangles];\n"))
      (fprintf out "meshEdges=sort([allTriangles(:,[1 2]);allTriangles(:,[2 3]);allTriangles(:,[3 1])],2);\n")
      (fprintf out "[~~,~~,edgeIds]=unique(meshEdges,'rows'); edgeCounts=accumarray(edgeIds,1);\n")
      (fprintf out "if any(edgeCounts ~~= 2); error('antenna-turtle:NonManifoldLoft','Loft is not a closed two-manifold.'); end\n")
      (fprintf out "fprintf(\"Loft mesh: %d vertices, %d triangles; every edge has two incident faces.\\n\", ...\n")
      (fprintf out "    size(allPoints,1),size(allTriangles,1));\n")
      (fprintf out "antennaShape=shape.Custom3D(triangulation(allTriangles,allPoints));\n")
      (fprintf out "antennaObject=customAntenna(Shape=antennaShape);\n")
      (unless (null? feeds)
        (define feed-edge (car feeds))
        (define midpoint (edge-midpoint feed-edge))
        (define direction (edge-direction feed-edge))
        (define half-diagonal (/ (wire-edge-diameter feed-edge) (sqrt 2)))
        (fprintf out "feedLocation=~a; feedDirection=~a;\n"
                 (point->matlab who midpoint) (point->matlab who direction))
        (fprintf out "feedHalfDiagonal=~a; feedTolerance=max(1e-10,feedHalfDiagonal*1e-3);\n"
                 (loft-number who half-diagonal))
        (fprintf out "geometryPoints=antennaObject.Shape.Points; geometryTriangles=antennaObject.Shape.Triangles(:,1:3);\n")
        (fprintf out "geometryEdges=edges(triangulation(geometryTriangles,geometryPoints));\n")
        (fprintf out "a=geometryPoints(geometryEdges(:,1),:)-feedLocation; b=geometryPoints(geometryEdges(:,2),:)-feedLocation;\n")
        (fprintf out "aa=a*feedDirection'; bb=b*feedDirection';\n")
        (fprintf out "ar=vecnorm(a-aa.*feedDirection,2,2); br=vecnorm(b-bb.*feedDirection,2,2);\n")
        (fprintf out "candidateMask=abs(aa)<=feedTolerance & abs(bb)<=feedTolerance & ...\n")
        (fprintf out "    abs(ar-feedHalfDiagonal)<=feedTolerance & abs(br-feedHalfDiagonal)<=feedTolerance;\n")
        (fprintf out "candidateFeedEdges=geometryEdges(candidateMask,:);\n")
        (fprintf out "fprintf(\"Loft feed contour: %d candidate edges (expected 4).\\n\",size(candidateFeedEdges,1));\n")
        (fprintf out "if size(candidateFeedEdges,1) ~~= 4; error('antenna-turtle:LoftFeedContour','Expected four feed edges.'); end\n")
        (fprintf out "createFeed(antennaObject,feedLocation,4);\n")
        (fprintf out "selectedFeedEdges=antennaObject.FeedEdges;\n")
        (fprintf out "candidateMatchesSelection=isequal(sortrows(sort(candidateFeedEdges,2)),sortrows(sort(selectedFeedEdges,2)));\n")
        (fprintf out "fprintf(\"Loft feed selected %d edges; candidate match = %d.\\n\",size(selectedFeedEdges,1),candidateMatchesSelection);\n"))
      (write-analysis out who (not (null? feeds)))
      (write-helper-functions out)))
  path)
