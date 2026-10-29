#lang racket/base

(require racket/file
         racket/list
         racket/math
         racket/path
         racket/promise
         racket/runtime-path
         racket/string
         "core.rkt"
         "export-common.rkt"
         "material.rkt"
         "nec2c-dielectric.rkt"
         "wire-lumped.rkt")

(provide export-nec2c
         write-nec2c-deck
         last-nec2c-export-path
         nec2c-feed-segment)

(define last-export (box #f))
;; Keep this as a runtime *path*, rather than a runtime module path.  The
;; latter asks the compilation manager to compile the optional surface module
;; while compiling this wire-only exporter, which fails on platforms where
;; Manifold is unavailable.
(define-runtime-path nec2c-surface-module "nec2c-surface.rkt")

;; Keep the wire-only language usable without the optional native Manifold
;; dependency.  When available, this module supplies refined MFIE patches and
;; rigidly translated wire coordinates for closed PEC surface bodies.
(define surface-api
  (delay
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (for/hash ([name
                  (in-list
                   '(model-nec2c-surface-geometry
                     nec2c-surface-geometry-patches
                     nec2c-surface-geometry-attachments
                     nec2c-surface-patch-center
                     nec2c-surface-patch-normal
                     nec2c-surface-patch-area
                     nec2c-surface-patch-corners
                     nec2c-adjusted-edge-point))])
        (values name (dynamic-require nec2c-surface-module name))))))

(define (surface-call name . arguments)
  (define api (force surface-api))
  (and api (apply (hash-ref api name) arguments)))

(define (last-nec2c-export-path)
  (define value (unbox last-export))
  (and value
       (eq? (car value) (current-antenna-model))
       (cdr value)))

(define (export-z z)
  (define translated (+ z (model-height)))
  (if (and (model-grounded?)
           (<= (abs translated) (snap-length)))
      0
      translated))

(define (pcoord who point accessor)
  (coordinate-string who (accessor point)))

(define (pcoord-z who point)
  (coordinate-string who (export-z (point3-z point))))

(define (validate-ground-geometry! who [surface-geometry #f])
  (when (model-grounded?)
    (for ([edge (in-list (model-edges))])
      (define start-z
        (export-z
         (point3-z (edge-export-point surface-geometry edge 'start))))
      (define end-z
        (export-z
         (point3-z (edge-export-point surface-geometry edge 'end))))
      (when (or (negative? start-z) (negative? end-z))
        (raise-arguments-error
         who
         "grounded NEC geometry may not extend below Z=0"
         "wire" (wire-edge-id edge)
         "start Z" start-z
         "end Z" end-z))
      (when (and (zero? start-z) (zero? end-z))
        (raise-arguments-error
         who
         "a NEC wire may not lie in the ground plane"
         "wire" (wire-edge-id edge))))
    (when surface-geometry
      (for* ([patch
              (in-list
               (surface-call
                'nec2c-surface-geometry-patches surface-geometry))]
             [corner
              (in-list (surface-call 'nec2c-surface-patch-corners patch))])
        (define z (export-z (point3-z corner)))
        (when (negative? z)
          (raise-arguments-error
           who
           "grounded NEC surface geometry may not extend below Z=0"
           "patch corner" corner
           "exported Z" z))))))

(define (write-ground-card out who)
  (define ground (model-ground))
  (case (ground-spec-kind ground)
    [(none) (void)]
    [(perfect) (displayln "GN 1" out)]
    [(real)
     (fprintf out "GN 2 0 0 0 ~a ~a\n"
              (coordinate-string who
                                 (ground-spec-relative-permittivity ground))
              (coordinate-string who (ground-spec-conductivity ground)))]))

(define (nec2c-feed-segment edge max-length)
  (define count (edge-segment-count edge max-length))
  (case (wire-edge-feed-location edge)
    [(start) 1]
    [(center) (quotient (add1 count) 2)]
    [(end) count]
    [else
     (raise-arguments-error
      'nec2c-feed-segment "edge does not contain a feed" "edge" edge)]))

(define (feed-voltage edge)
  (define magnitude (wire-edge-feed-amplitude edge))
  (define radians (degrees->radians (wire-edge-feed-phase edge)))
  (make-rectangular (* magnitude (cos radians))
                    (* magnitude (sin radians))))

(define radians->degrees-factor (/ 180 pi))

(struct resolved-wire-load
  (element vertex negative-edge positive-edge negative-point positive-point
           tag diameter)
  #:transparent)

(define (point-distance first second)
  (sqrt (+ (sqr (- (point3-x first) (point3-x second)))
           (sqr (- (point3-y first) (point3-y second)))
           (sqr (- (point3-z first) (point3-z second))))))

(define (point-subtract first second)
  (point3 (- (point3-x first) (point3-x second))
          (- (point3-y first) (point3-y second))
          (- (point3-z first) (point3-z second))))

(define (point-add-scaled point direction scale)
  (point3 (+ (point3-x point) (* scale (point3-x direction)))
          (+ (point3-y point) (* scale (point3-y direction)))
          (+ (point3-z point) (* scale (point3-z direction)))))

(define (point-normalize who point description)
  (define length (sqrt (+ (sqr (point3-x point))
                          (sqr (point3-y point))
                          (sqr (point3-z point)))))
  (when (zero? length)
    (raise-arguments-error who "zero-length direction" description point))
  (point3 (/ (point3-x point) length)
          (/ (point3-y point) length)
          (/ (point3-z point) length)))

(define (point-dot first second)
  (+ (* (point3-x first) (point3-x second))
     (* (point3-y first) (point3-y second))
     (* (point3-z first) (point3-z second))))

(define (edge-end-at-vertex edge vertex)
  (cond [(eq? (wire-edge-start edge) vertex) 'start]
        [(eq? (wire-edge-end edge) vertex) 'end]
        [else #f]))

(define (edge-other-point edge end)
  (vertex-point ((if (eq? end 'start) wire-edge-end wire-edge-start) edge)))

(define (feed-at-edge-end? edge end)
  (and (wire-edge-feed? edge)
       (eq? (wire-edge-feed-location edge) end)))

(define (resolve-wire-loads who)
  (define elements (model-wire-lumped-elements))
  (define tolerance (max (snap-length) 1e-12))
  (define used-vertices (make-hasheq))
  (define next-tag
    (add1 (for/fold ([largest 0]) ([edge (in-list (model-edges))])
            (max largest (wire-edge-id edge)))))
  (for/list ([element (in-list elements)] [offset (in-naturals)])
    (define nearby
      (for/list ([vertex (in-list (model-vertices))]
                 #:when (<= (point-distance
                             (wire-lumped-element-center element)
                             (vertex-point vertex))
                            tolerance))
        vertex))
    (unless (= (length nearby) 1)
      (raise-arguments-error
       who
       "wire lumped element must resolve to exactly one wire vertex"
       "element" (wire-lumped-element-name element)
       "matching vertices" (length nearby)
       "tolerance (m)" tolerance))
    (define vertex (first nearby))
    (when (hash-has-key? used-vertices vertex)
      (raise-arguments-error
       who "only one wire lumped element may occupy a vertex"
       "element" (wire-lumped-element-name element)))
    (hash-set! used-vertices vertex #t)
    (define incidents
      (for/list ([edge (in-list (model-edges))]
                 #:when (edge-end-at-vertex edge vertex))
        edge))
    (unless (= (length incidents) 2)
      (raise-arguments-error
       who "wire lumped element requires a degree-two wire vertex"
       "element" (wire-lumped-element-name element)
       "incident wires" (length incidents)))
    (define direction
      (point-normalize who (wire-lumped-element-direction element)
                       "lumped-element direction"))
    (define classified
      (for/list ([edge (in-list incidents)])
        (define end (edge-end-at-vertex edge vertex))
        (define outward
          (point-normalize who
                           (point-subtract (edge-other-point edge end)
                                           (vertex-point vertex))
                           "incident wire direction"))
        (list edge end (point-dot outward direction))))
    (define negative (filter (lambda (entry) (< (third entry) -0.99999999)) classified))
    (define positive (filter (lambda (entry) (> (third entry) 0.99999999)) classified))
    (unless (and (= (length negative) 1) (= (length positive) 1))
      (raise-arguments-error
       who "wire lumped element requires collinear wires along its direction"
       "element" (wire-lumped-element-name element)
       "direction cosines" (map third classified)))
    (define negative-entry (first negative))
    (define positive-entry (first positive))
    (define negative-edge (first negative-entry))
    (define positive-edge (first positive-entry))
    (when (or (feed-at-edge-end? negative-edge (second negative-entry))
              (feed-at-edge-end? positive-edge (second positive-entry)))
      (raise-arguments-error
       who "a feed and wire lumped element may not occupy the same vertex"
       "element" (wire-lumped-element-name element)))
    (define half-gap (/ (wire-lumped-element-gap element) 2.0))
    (for ([edge (in-list (list negative-edge positive-edge))])
      (unless (> (edge-length edge) half-gap)
        (raise-arguments-error
         who "adjacent wire is too short for the lumped-element gap"
         "element" (wire-lumped-element-name element)
         "gap (m)" (wire-lumped-element-gap element)
         "wire length (m)" (edge-length edge))))
    (define negative-diameter (wire-edge-diameter negative-edge))
    (define positive-diameter (wire-edge-diameter positive-edge))
    (unless (<= (abs (- negative-diameter positive-diameter))
                (max 1e-12 (* 1e-9 (max negative-diameter positive-diameter))))
      (raise-arguments-error
       who "wires adjacent to a lumped element must have equal diameters"
       "element" (wire-lumped-element-name element)
       "diameters" (list negative-diameter positive-diameter)))
    (resolved-wire-load
     element vertex negative-edge positive-edge
     (point-add-scaled (vertex-point vertex) direction (- half-gap))
     (point-add-scaled (vertex-point vertex) direction half-gap)
     (+ next-tag offset) negative-diameter)))

(define (wire-load-endpoint-overrides loads)
  (define overrides (make-hasheq))
  (define (set-end! edge vertex point)
    (define ends (hash-ref overrides edge (lambda () (make-hasheq))))
    (hash-set! ends (edge-end-at-vertex edge vertex) point)
    (hash-set! overrides edge ends))
  (for ([load (in-list loads)])
    (set-end! (resolved-wire-load-negative-edge load)
              (resolved-wire-load-vertex load)
              (resolved-wire-load-negative-point load))
    (set-end! (resolved-wire-load-positive-edge load)
              (resolved-wire-load-vertex load)
              (resolved-wire-load-positive-point load)))
  overrides)

(define (write-wire-load-card out who load)
  (define element (resolved-wire-load-element load))
  (fprintf out "LD ~a ~a 1 1 ~a ~a ~a\n"
           (if (eq? (wire-lumped-element-topology element) 'series) 0 1)
           (resolved-wire-load-tag load)
           (coordinate-string who (or (wire-lumped-element-resistance element) 0))
           (coordinate-string who (or (wire-lumped-element-inductance element) 0))
           (coordinate-string who (or (wire-lumped-element-capacitance element) 0))))

(define (write-surface-patches out who surface-geometry)
  (when surface-geometry
    (for ([patch
           (in-list
            (surface-call 'nec2c-surface-geometry-patches surface-geometry))])
      (define center (surface-call 'nec2c-surface-patch-center patch))
      (define normal (surface-call 'nec2c-surface-patch-normal patch))
      (define elevation
        (* radians->degrees-factor (asin (max -1 (min 1 (point3-z normal))))))
      (define azimuth
        (if (and (zero? (point3-x normal)) (zero? (point3-y normal)))
            0
            (* radians->degrees-factor
               (atan (point3-y normal) (point3-x normal)))))
      ;; Arbitrary-shape SP patches retain precisely the centroid, outward
      ;; normal, and area that NEC uses.  At a wire junction NEC assumes the
      ;; patch is square and subdivides it into four connection patches.
      (fprintf out "SP 0 0 ~a ~a ~a ~a ~a ~a\n"
               (pcoord who center point3-x)
               (pcoord who center point3-y)
               (pcoord-z who center)
               (coordinate-string who elevation)
               (coordinate-string who azimuth)
               (coordinate-string
                who (surface-call 'nec2c-surface-patch-area patch))))))

(define (edge-export-point surface-geometry edge end)
  (if surface-geometry
      (surface-call 'nec2c-adjusted-edge-point surface-geometry edge end)
      (vertex-point
       ((if (eq? end 'start) wire-edge-start wire-edge-end) edge))))

(define (write-nec2c-deck out [analysis-cards '()]
                           #:dielectric-resource [dielectric-resource #f])
  (define who 'export-nec2c)
  (define max-length (require-segmentation! who))
  (define surface-candidate
    (surface-call 'model-nec2c-surface-geometry))
  (define surface-geometry
    (and surface-candidate
         (pair?
          (surface-call
           'nec2c-surface-geometry-patches surface-candidate))
         surface-candidate))
  (define wire-loads (resolve-wire-loads who))
  (when (and surface-geometry (pair? wire-loads))
    (raise-arguments-error
     who "wire lumped elements are not yet supported with NEC surface bodies"))
  (define endpoint-overrides (wire-load-endpoint-overrides wire-loads))
  (validate-ground-geometry! who surface-geometry)
  (fprintf out "CM ~a\n" (model-title))
  (fprintf out "CM Generated by antenna-turtle; coordinates are meters\n")
  (when surface-geometry
    (fprintf out "CM ~a NEC2 MFIE surface patches; ~a wire attachments\n"
             (length
              (surface-call
               'nec2c-surface-geometry-patches surface-geometry))
             (length
              (surface-call
               'nec2c-surface-geometry-attachments surface-geometry))))
  (when (pair? wire-loads)
    (fprintf out "CM ~a inline NEC lumped element~a\n"
             (length wire-loads) (if (= (length wire-loads) 1) "" "s")))
  (fprintf out "CE\n")
  (write-surface-patches out who surface-geometry)
  (for ([edge (in-list (model-edges))])
    (define ends (hash-ref endpoint-overrides edge #f))
    (define a (if (and ends (hash-has-key? ends 'start))
                  (hash-ref ends 'start)
                  (edge-export-point surface-geometry edge 'start)))
    (define b (if (and ends (hash-has-key? ends 'end))
                  (hash-ref ends 'end)
                  (edge-export-point surface-geometry edge 'end)))
    (define count (edge-segment-count edge max-length))
    (fprintf out
             "GW ~a ~a ~a ~a ~a ~a ~a ~a ~a\n"
             (wire-edge-id edge)
             count
             (pcoord who a point3-x)
             (pcoord who a point3-y)
             (pcoord-z who a)
             (pcoord who b point3-x)
             (pcoord who b point3-y)
             (pcoord-z who b)
             (coordinate-string who (/ (wire-edge-diameter edge) 2))))
  (for ([load (in-list wire-loads)])
    (fprintf out "GW ~a 1 ~a ~a ~a ~a ~a ~a ~a\n"
             (resolved-wire-load-tag load)
             (pcoord who (resolved-wire-load-negative-point load) point3-x)
             (pcoord who (resolved-wire-load-negative-point load) point3-y)
             (pcoord-z who (resolved-wire-load-negative-point load))
             (pcoord who (resolved-wire-load-positive-point load) point3-x)
             (pcoord who (resolved-wire-load-positive-point load) point3-y)
             (pcoord-z who (resolved-wire-load-positive-point load))
             (coordinate-string who (/ (resolved-wire-load-diameter load) 2))))
  ;; GE 1 makes wire endpoints at Z=0 connect to their ground-plane image.
  ;; Free-space geometry deliberately retains GE 0.
  (fprintf out "GE ~a\n" (if (model-grounded?) 1 0))
  (when dielectric-resource
    (unless (and (string? dielectric-resource)
                 (not (string=? dielectric-resource ""))
                 (not (string-contains? dielectric-resource "\r"))
                 (not (string-contains? dielectric-resource "\n"))
                 (not (string-contains? dielectric-resource "\"")))
      (raise-argument-error
       'write-nec2c-deck "non-empty string without quote or newline"
       dielectric-resource))
    (fprintf out "DF \"~a\"\n" dielectric-resource))
  (write-ground-card out who)
  (for ([load (in-list wire-loads)])
    (write-wire-load-card out who load))
  (for ([edge (in-list (model-edges))]
        #:when (wire-edge-feed? edge))
    (define voltage (feed-voltage edge))
    (fprintf out "EX 0 ~a ~a 0 ~a ~a\n"
             (wire-edge-id edge)
             (nec2c-feed-segment edge max-length)
             (coordinate-string who (real-part voltage))
             (coordinate-string who (imag-part voltage))))
  (for ([card (in-list analysis-cards)])
    (unless (string? card)
      (raise-argument-error 'write-nec2c-deck "string?" card))
    (displayln card out))
  (fprintf out "EN\n"))

(define (delete-if-exists path)
  (when (and path (file-exists? path)) (delete-file path)))

(define (export-nec2c path #:dielectrics? [dielectrics? #t])
  (validate-model!)
  (unless (boolean? dielectrics?)
    (raise-argument-error 'export-nec2c "boolean?" dielectrics?))
  (define dielectric-cuboids
    (and dielectrics?
         (filter
          (lambda (cuboid)
            (eq? (em-material-kind (model-cuboid-material cuboid)) 'dielectric))
          (model-cuboids))))
  (define target (simplify-path (path->complete-path path)))
  (define directory (or (path-only target) (current-directory)))
  (define resource-path
    (and (pair? dielectric-cuboids) (path-replace-extension target #".diel")))
  (define resource-leaf
    (and resource-path (path->string (file-name-from-path resource-path))))
  (define deck-temporary
    (make-temporary-file "antenna-turtle-deck~a.tmp" #f directory))
  (define resource-temporary
    (and resource-path
         (make-temporary-file "antenna-turtle-resource~a.tmp" #f directory)))
  (with-handlers ([exn?
                   (lambda (exception)
                     (delete-if-exists deck-temporary)
                     (delete-if-exists resource-temporary)
                     (raise exception))])
    (when resource-temporary
      (call-with-output-file resource-temporary
        #:exists 'truncate/replace
        (lambda (out)
          (write-nec2c-dielectric-resource out #:cuboids dielectric-cuboids))))
    (call-with-output-file deck-temporary
      #:exists 'truncate/replace
      (lambda (out)
        (write-nec2c-deck
         out #:dielectric-resource resource-leaf)))
    ;; The deck is the commit point: publish its resource first, then the deck
    ;; which refers to it.
    (when resource-temporary
      (rename-file-or-directory resource-temporary resource-path #t))
    (rename-file-or-directory deck-temporary target #t))
  (set-box! last-export
            (cons (current-antenna-model)
                  target))
  path)
