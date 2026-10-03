#lang racket/base

(require racket/list
         racket/string
         "core.rkt"
         "export-common.rkt")

(provide export-matlab)

(struct mesh-builder (points triangles feed-points vertex-joins) #:mutable)
(struct vertex-join (plus-id minus-id offset) #:transparent)

(define (p+ a b)
  (point3 (+ (point3-x a) (point3-x b))
          (+ (point3-y a) (point3-y b))
          (+ (point3-z a) (point3-z b))))

(define (p- a b)
  (point3 (- (point3-x a) (point3-x b))
          (- (point3-y a) (point3-y b))
          (- (point3-z a) (point3-z b))))

(define (p* factor p)
  (point3 (* factor (point3-x p))
          (* factor (point3-y p))
          (* factor (point3-z p))))

(define (dot a b)
  (+ (* (point3-x a) (point3-x b))
     (* (point3-y a) (point3-y b))
     (* (point3-z a) (point3-z b))))

(define (cross a b)
  (point3 (- (* (point3-y a) (point3-z b))
             (* (point3-z a) (point3-y b)))
          (- (* (point3-z a) (point3-x b))
             (* (point3-x a) (point3-z b)))
          (- (* (point3-x a) (point3-y b))
             (* (point3-y a) (point3-x b)))))

(define (magnitude p) (sqrt (dot p p)))
(define (normalize p) (p* (/ 1 (magnitude p)) p))
(define (midpoint a b) (p* 1/2 (p+ a b)))

(define (transverse-unit/direction direction)
  (define z-axis (point3 0 0 1))
  (define y-axis (point3 0 1 0))
  ;; Use a stable fallback when the edge is nearly parallel with global Z.
  (normalize (cross direction
                    (if (> (abs (dot direction z-axis)) 0.9)
                        y-axis
                        z-axis))))

(define (edge-direction edge)
  (normalize
   (p- (vertex-point (wire-edge-end edge))
       (vertex-point (wire-edge-start edge)))))

(define (transverse-unit edge)
  (transverse-unit/direction (edge-direction edge)))

(define (same-vertex? a b)
  (= (vertex-id a) (vertex-id b)))

(define (edge-starts-at? edge v)
  (same-vertex? (wire-edge-start edge) v))

(define (edge-ends-at? edge v)
  (same-vertex? (wire-edge-end edge) v))

(define (incident-edges v)
  (filter (lambda (edge)
            (or (edge-starts-at? edge v)
                (edge-ends-at? edge v)))
          (model-edges)))

(define (aligned-with reference candidate)
  (if (< (dot reference candidate) 0)
      (p* -1 candidate)
      candidate))

(define (join-offset v edges)
  (define half-width
    (/ (apply max (map wire-edge-diameter edges)) 2))
  (cond
    [(null? (cdr edges))
     (p* half-width (transverse-unit (car edges)))]
    [else
     ;; For the usual degree-two path, orient one tangent into the vertex and
     ;; the other out of it. This produces the standard miter direction for a
     ;; planar bend. A branch reuses the same join edge for all incident
     ;; strips; this is deliberately only an approximation.
     (define incoming
       (for/first ([edge (in-list edges)] #:when (edge-ends-at? edge v)) edge))
     (define outgoing
       (for/first ([edge (in-list edges)]
                   #:when (and (edge-starts-at? edge v)
                               (not (eq? edge incoming))))
         edge))
     (define first-edge (or incoming (car edges)))
     (define second-edge
       (or outgoing
           (for/first ([edge (in-list edges)] #:unless (eq? edge first-edge))
             edge)))
     (define first-tangent
       (if (edge-ends-at? first-edge v)
           (edge-direction first-edge)
           (p* -1 (edge-direction first-edge))))
     (define second-tangent
       (if (edge-starts-at? second-edge v)
           (edge-direction second-edge)
           (p* -1 (edge-direction second-edge))))
     (define first-normal (transverse-unit/direction first-tangent))
     (define second-normal
       (aligned-with first-normal
                     (transverse-unit/direction second-tangent)))
     (define summed (p+ first-normal second-normal))
     (define miter-direction
       (if (< (magnitude summed) 1e-12)
           first-normal
           (normalize summed)))
     (define projection
       (max 1e-12
            (min (abs (dot miter-direction first-normal))
                 (abs (dot miter-direction second-normal)))))
     ;; A cap prevents nearly reversing paths from producing enormous spikes.
     (p* (min (/ half-width projection) (* 4 half-width))
         miter-direction)]))

(define (append-point! mesh point)
  (define next-id (add1 (length (mesh-builder-points mesh))))
  (set-mesh-builder-points!
   mesh (append (mesh-builder-points mesh) (list point)))
  next-id)

(define (append-triangle! mesh a b c)
  (set-mesh-builder-triangles!
   mesh (append (mesh-builder-triangles mesh) (list (list a b c)))))

(define (build-vertex-joins! mesh)
  (for ([v (in-list (model-vertices))])
    (define edges (incident-edges v))
    (unless (null? edges)
      (define offset (join-offset v edges))
      (define center (vertex-point v))
      (define plus-id (append-point! mesh (p+ center offset)))
      (define minus-id (append-point! mesh (p- center offset)))
      (hash-set! (mesh-builder-vertex-joins mesh)
                 (vertex-id v)
                 (vertex-join plus-id minus-id offset)))))

(define (edge-join-ids mesh v normal)
  (define join
    (hash-ref (mesh-builder-vertex-joins mesh) (vertex-id v)))
  (if (negative? (dot (vertex-join-offset join) normal))
      (values (vertex-join-minus-id join) (vertex-join-plus-id join))
      (values (vertex-join-plus-id join) (vertex-join-minus-id join))))

(define (append-strip! mesh edge)
  (define a (vertex-point (wire-edge-start edge)))
  (define b (vertex-point (wire-edge-end edge)))
  (define m (midpoint a b))
  (define normal (transverse-unit edge))
  (define half-width
    (p* (/ (wire-edge-diameter edge) 2) normal))
  (define-values (al ar)
    (edge-join-ids mesh (wire-edge-start edge) normal))
  (define-values (bl br)
    (edge-join-ids mesh (wire-edge-end edge) normal))
  (if (wire-edge-feed? edge)
      (let* ([m-left (p+ m half-width)]
             [m-right (p- m half-width)]
             [ml (append-point! mesh m-left)]
             [mr (append-point! mesh m-right)])
        (append-triangle! mesh al ar mr)
        (append-triangle! mesh al mr ml)
        (append-triangle! mesh ml mr br)
        (append-triangle! mesh ml br bl)
        (set-mesh-builder-feed-points!
         mesh (append (mesh-builder-feed-points mesh) (list m))))
      (begin
        (append-triangle! mesh al ar br)
        (append-triangle! mesh al br bl))))

(define (write-matrix out name rows who [formatter #f])
  (fprintf out "~a = [ ...\n" name)
  (for ([row (in-list rows)])
    (fprintf out "    ~a; ...\n"
             (string-join
              (for/list ([value (in-list row)])
                (if formatter
                    (formatter value)
                    (coordinate-string who value)))
              " ")))
  (fprintf out "];\n\n"))

(define (point->row point)
  (list (point3-x point) (point3-y point) (point3-z point)))

(define (export-matlab path)
  (validate-model!)
  (define who 'export-matlab)
  (when (null? (model-edges))
    (error who "cannot export an empty model"))
  (define mesh (mesh-builder '() '() '() (make-hash)))
  (build-vertex-joins! mesh)
  (for ([edge (in-list (model-edges))])
    (append-strip! mesh edge))
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (out)
      (fprintf out "%% ~a\n" (model-title))
      (fprintf out "%% Generated by antenna-turtle. Geometry units are meters.\n")
      (fprintf out "%% Rectangular strips approximate the DSL's cylindrical wires.\n\n")
      (write-matrix out "points" (map point->row (mesh-builder-points mesh)) who)
      (write-matrix out "triangles" (mesh-builder-triangles mesh) who number->string)
      (fprintf out "meshData = triangulation(triangles, points);\n")
      (fprintf out "antennaShape = shape.Custom3D(meshData);\n")
      (fprintf out "antennaObject = customAntenna(Shape=antennaShape);\n")
      (unless (null? (mesh-builder-feed-points mesh))
        (write-matrix out "feedLocations"
                      (map point->row (mesh-builder-feed-points mesh)) who)
        (fprintf out "feedEdgeCounts = ones(1, size(feedLocations, 1));\n")
        (fprintf out "createFeed(antennaObject, feedLocations, feedEdgeCounts);\n"))
      (fprintf out "\nfigure;\nshow(antennaObject);\n")
      (fprintf out "\n%% Far-field analysis\n")
      (fprintf out "% Edit this frequency as needed; it is initialized from model-frequency.\n")
      (fprintf out "operatingFrequency = ~a; % Hz\n"
               (coordinate-string who (* 1000000 (model-frequency))))
      (if (null? (mesh-builder-feed-points mesh))
          (begin
            (fprintf out "% A feed is required before field analysis.\n")
            (fprintf out "% figure;\n")
            (fprintf out "% pattern(antennaObject, operatingFrequency, Type=\"directivity\");\n"))
          (begin
            (fprintf out "figure;\n")
            (fprintf out "pattern(antennaObject, operatingFrequency, Type=\"directivity\");\n")))))
  path)
