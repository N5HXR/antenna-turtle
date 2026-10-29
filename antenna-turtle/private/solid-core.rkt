#lang racket/base

(require racket/list
         racket/math
         (prefix-in m: manifold)
         "core.rkt"
         "material.rkt"
         "mesh-constraint.rkt"
         "nec2c-dielectric.rkt"
         "lumped-component.rkt"
         "wire-lumped.rkt"
         "solid-placement.rkt")

(provide
 (all-from-out "material.rkt")
 (all-from-out "mesh-constraint.rkt")

 (struct-out solid-body)
 (struct-out planar-sheet)
 (struct-out lumped-port)
 (struct-out lumped-component)
 (struct-out solid-scene)
 current-solid-scene
 model-bodies
 model-sheets
 model-ports
 model-components
 add-body
 add-sheet
 add-sheet/world-polygons
 add-lumped-port
 add-lumped-element
 lumped-port-start
 lumped-port-stop
 clear-bodies
 validate-solid-scene!)

(define (finite-real? value)
  (and (real? value) (rational? value)))

(define (positive-real who value description)
  (unless (and (finite-real? value) (positive? value))
    (raise-arguments-error who
                           (format "~a must be a positive finite real" description)
                           description value))
  value)

(define (nonnegative-real who value description)
  (unless (and (finite-real? value) (>= value 0))
    (raise-arguments-error
     who (format "~a must be a nonnegative finite real" description)
     description value))
  value)

;; A scene owns the transformed Manifold handles stored in its bodies. The
;; caller retains ownership of the source solid passed to add-body.
(struct solid-body
  (name material solid priority coordinates placement-transform metal-thickness
        form material-source)
  #:transparent)
(struct planar-sheet
  (name material points normal priority placement-transform mesh-edges thickness
        polygons boundaries trace-width)
  #:transparent)
(struct lumped-port
  (name impedance center direction transverse-u transverse-v
        gap width depth priority placement-transform)
  #:transparent)
(struct solid-scene (bodies sheets ports components) #:mutable #:transparent)

(define current-solid-scene
  (make-parameter (solid-scene '() '() '() '())))

(define (model-bodies [scene (current-solid-scene)])
  (solid-scene-bodies scene))

(define (model-sheets [scene (current-solid-scene)])
  (solid-scene-sheets scene))

(define (model-ports [scene (current-solid-scene)])
  (solid-scene-ports scene))

(define (model-components [scene (current-solid-scene)])
  (solid-scene-components scene))

(define identity-transform
  '((1 0 0 0)
    (0 1 0 0)
    (0 0 1 0)))

(define (scene-transform who coordinates)
  (case coordinates
    [(local) (current-turtle-affine-transform who)]
    [(world) identity-transform]
    [else
     (raise-argument-error who "(or/c 'local 'world)" coordinates)]))

(define (effective-precedence who priority precedence)
  (when (and priority precedence)
    (raise-arguments-error
     who "use either priority or precedence, not both"
     "priority" priority "precedence" precedence))
  (define value (or precedence priority))
  (validate-priority who value)
  value)

(define (metal-material? material)
  (memq (em-material-kind material) '(pec conductor conducting-sheet)))

(define (effective-sheet-thickness who material explicit-thickness scale-factor)
  (when explicit-thickness
    (nonnegative-real who explicit-thickness "sheet thickness"))
  (cond
    ;; Explicit geometry is expressed in the active modeling units.
    [explicit-thickness (* scale-factor explicit-thickness)]
    ;; A normal conductor catalog value is already an absolute SI thickness.
    [(eq? (em-material-kind material) 'conductor)
     (em-material-thickness material)]
    ;; Preserve the historical scale-relative conducting-sheet constructor.
    [(eq? (em-material-kind material) 'conducting-sheet)
     (and (em-material-thickness material)
          (* scale-factor (em-material-thickness material)))]
    [else #f]))

(define (geometry-name who value)
  (unless (or (symbol? value)
              (and (string? value) (not (string=? value ""))))
    (raise-argument-error who "(or/c symbol? non-empty-string?)" value))
  value)

(define (validate-material who value)
  (unless (em-material? value)
    (raise-argument-error who "em-material?" value))
  value)

(define (validate-priority who value)
  (unless (or (not value) (exact-integer? value))
    (raise-argument-error who "(or/c #f exact-integer?)" value))
  value)

(define (used-name? name [scene (current-solid-scene)])
  (or (for/or ([body (in-list (solid-scene-bodies scene))])
        (equal? name (solid-body-name body)))
      (for/or ([sheet (in-list (solid-scene-sheets scene))])
        (equal? name (planar-sheet-name sheet)))
      (for/or ([port (in-list (solid-scene-ports scene))])
        (equal? name (lumped-port-name port)))
      (for/or ([component (in-list (solid-scene-components scene))])
        (equal? name (lumped-component-name component)))))

(define (fresh-feature-name prefix [scene (current-solid-scene)])
  ;; An omitted name is an identity, not a label. An uninterned symbol cannot
  ;; collide with either another generated identity or a programmer's symbol.
  (gensym prefix))

(define (effective-feature-name who requested prefix [scene (current-solid-scene)])
  (when requested (geometry-name who requested))
  (define result (or requested (fresh-feature-name prefix scene)))
  (when (used-name? result scene)
    (raise-arguments-error who "explicit model feature names must be unique"
                           "name" result))
  result)

(define (add-body name material geometry
                  #:priority [priority #f]
                  #:precedence [precedence #f]
                  #:coordinates [coordinates 'local]
                  #:anchor [anchor 'origin]
                  #:metal-thickness [metal-thickness #f]
                  #:form [form 'solid]
                  #:material-source [material-source 'explicit-or-context])
  (define effective-name (effective-feature-name 'add-body name 'body))
  (validate-material 'add-body material)
  (unless (memq form '(solid surface))
    (raise-argument-error 'add-body "(or/c 'solid 'surface)" form))
  (unless (memq material-source '(explicit-or-context forced-by-surface-form))
    (raise-argument-error
     'add-body
     "(or/c 'explicit-or-context 'forced-by-surface-form)"
     material-source))
  (when (and (eq? form 'surface)
             (not (eq? (em-material-kind material) 'pec)))
    (raise-arguments-error
     'add-body "surface-form bodies must use PEC"
     "material" material))
  (when (eq? material-source 'forced-by-surface-form)
    (printf
     "Antenna Turtle material notice: body ~a uses form surface; modeling its boundary as PEC.\n"
     effective-name))
  (define effective-priority
    (effective-precedence 'add-body priority precedence))
  (when metal-thickness
    (positive-real 'add-body metal-thickness "metal thickness"))
  (when (and (eq? (em-material-kind material) 'conductor)
             (not metal-thickness))
    (raise-arguments-error
     'add-body "finite-conductivity bodies require metal-thickness"
     "material" material))
  (unless (m:solid? geometry)
    (raise-argument-error 'add-body "solid? from manifold" geometry))
  (when (m:solid-closed? geometry)
    (raise-arguments-error 'add-body "source solid has been closed"
                           "geometry" geometry))
  (define placement
    (scale-transform (scene-transform 'add-body coordinates)
                     (current-geometry-scale)))
  (define anchor-point (solid-anchor-point 'add-body geometry anchor))
  (define effective-placement
    (for/list ([row (in-list placement)])
      (append (take row 3)
              (list (- (fourth row)
                       (for/sum ([coefficient (in-list (take row 3))]
                                 [coordinate (in-list anchor-point)])
                         (* coefficient coordinate)))))))
  ;; transform always returns a distinct native handle, including identity.
  (define owned-solid (m:transform geometry effective-placement))
  (define body
    (solid-body effective-name material owned-solid effective-priority
                coordinates effective-placement
                (and metal-thickness
                     (* (current-geometry-scale) metal-thickness))
                form material-source))
  (define scene (current-solid-scene))
  (set-solid-scene-bodies!
   scene (append (solid-scene-bodies scene) (list body)))
  body)

(define (add-sheet name material points
                   #:priority [priority #f]
                   #:precedence [precedence #f]
                   #:coordinates [coordinates 'local]
                   #:mesh-edges [mesh-edges #f]
                   #:thickness [thickness #f])
  (define effective-name (effective-feature-name 'add-sheet name 'sheet))
  (validate-material 'add-sheet material)
  (unless (memq (em-material-kind material) '(pec conductor conducting-sheet))
    (raise-arguments-error
     'add-sheet "sheet material must be PEC or a conductor"
     "material" material))
  (define effective-priority
    (effective-precedence 'add-sheet priority precedence))
  (unless (memq mesh-edges '(#f exact metal))
    (raise-argument-error 'add-sheet "(or/c #f 'exact 'metal)" mesh-edges))
  (define effective-mesh-edges
    (or mesh-edges (if (metal-material? material) 'metal 'exact)))
  (unless (and (list? points) (>= (length points) 3))
    (raise-argument-error 'add-sheet "list of at least three 2D points" points))
  (define orientation (scene-transform 'add-sheet coordinates))
  (define scale-factor (current-geometry-scale))
  (define placement (scale-transform orientation scale-factor))
  (define effective-thickness
    (effective-sheet-thickness 'add-sheet material thickness scale-factor))
  (when (and (eq? (em-material-kind material) 'conductor)
             (not effective-thickness))
    (raise-arguments-error
     'add-sheet "finite-conductivity sheets require thickness on the sheet or material"
     "material" material))
  ;; Preserve the historical material accessor for compatibility while also
  ;; storing thickness on the placed sheet, where new conductor materials need
  ;; it to live.
  (define effective-material
    (if (and (eq? (em-material-kind material) 'conducting-sheet)
             effective-thickness)
        (struct-copy em-material material [thickness effective-thickness])
        material))
  (define world-points
    (for/list ([point (in-list points)])
      (define xy (point-values 'add-sheet point 2))
      (transform-point placement (list (first xy) (second xy) 0))))
  (define sheet
    (planar-sheet effective-name effective-material world-points
                  (transform-vector orientation '(0 0 1))
                  effective-priority placement effective-mesh-edges effective-thickness
                  (list world-points) (list world-points) #f))
  (define scene (current-solid-scene))
  (set-solid-scene-sheets!
   scene (append (solid-scene-sheets scene) (list sheet)))
  sheet)

(define (add-sheet/world-polygons name material polygons boundaries normal
                                  #:priority [priority #f]
                                  #:precedence [precedence #f]
                                  #:mesh-edges [mesh-edges 'metal]
                                  #:thickness [thickness #f]
                                  #:trace-width [trace-width #f])
  (define effective-name (effective-feature-name 'with-traces name 'trace))
  (validate-material 'with-traces material)
  (unless (memq (em-material-kind material) '(pec conductor conducting-sheet))
    (raise-arguments-error 'with-traces
                           "trace material must be PEC or a conductor"
                           "material" material))
  (unless (and (list? polygons) (pair? polygons)
               (andmap (lambda (polygon)
                         (and (list? polygon) (>= (length polygon) 3)
                              (andmap point3? polygon)))
                       polygons))
    (raise-argument-error 'with-traces
                          "nonempty list of point3 polygons" polygons))
  (unless (and (list? boundaries) (pair? boundaries)
               (andmap (lambda (boundary)
                         (and (list? boundary) (>= (length boundary) 3)
                              (andmap point3? boundary)))
                       boundaries))
    (raise-argument-error 'with-traces
                          "nonempty list of point3 boundaries" boundaries))
  (unless (point3? normal)
    (raise-argument-error 'with-traces "point3? normal" normal))
  (unless (memq mesh-edges '(exact metal))
    (raise-argument-error 'with-traces "(or/c 'exact 'metal)" mesh-edges))
  (define effective-priority
    (or (effective-precedence 'with-traces priority precedence)
        (material-default-precedence material)))
  (define scale-factor (current-geometry-scale))
  (define effective-thickness
    (effective-sheet-thickness 'with-traces material thickness scale-factor))
  (when (and (eq? (em-material-kind material) 'conductor)
             (not effective-thickness))
    (raise-arguments-error 'with-traces
                           "finite-conductivity traces require thickness on the trace or material"
                           "material" material))
  (define effective-material
    (if (and (eq? (em-material-kind material) 'conducting-sheet)
             effective-thickness)
        (struct-copy em-material material [thickness effective-thickness])
        material))
  (define sheet
    ;; `points` remains the authoritative exterior outline for compatibility;
    ;; `polygons` may be a triangulated fill for a concave trace.
    (planar-sheet effective-name effective-material (first boundaries) normal
                  effective-priority identity-transform mesh-edges
                  effective-thickness polygons boundaries trace-width))
  (define scene (current-solid-scene))
  (set-solid-scene-sheets!
   scene (append (solid-scene-sheets scene) (list sheet)))
  sheet)

(define direction-components
  (hash 'forward '(1 0 0)
        'forwards '(1 0 0)
        'back '(-1 0 0)
        'backward '(-1 0 0)
        'backwards '(-1 0 0)
        'left '(0 1 0)
        'right '(0 -1 0)
        'up '(0 0 1)
        'down '(0 0 -1)))

(define transverse-components
  ;; The ordering merely defines how width and depth are displayed. All three
  ;; vectors remain a right-handed local frame for the positive directions;
  ;; polarity reversal does not change the port box.
  (hash 'forward (list '(0 1 0) '(0 0 1))
        'forwards (list '(0 1 0) '(0 0 1))
        'back (list '(0 1 0) '(0 0 1))
        'backward (list '(0 1 0) '(0 0 1))
        'backwards (list '(0 1 0) '(0 0 1))
        'left (list '(1 0 0) '(0 0 1))
        'right (list '(1 0 0) '(0 0 1))
        'up (list '(1 0 0) '(0 1 0))
        'down (list '(1 0 0) '(0 1 0))))

(define (fresh-port-name [scene (current-solid-scene)])
  (fresh-feature-name 'port scene))

(define automatic-port-dimension (gensym 'automatic-port-dimension))

(define (anchored-feature-center who anchor origin direction gap)
  (unless (memq anchor '(start center end))
    (raise-argument-error who "(or/c 'start 'center 'end)" anchor))
  (case anchor
    [(start) (point+scaled origin direction (/ gap 2))]
    [(end) (point+scaled origin direction (- (/ gap 2)))]
    [else origin]))

(define (add-lumped-port direction
                         #:name [requested-name #f]
                         #:impedance [impedance (model-impedance)]
                         #:gap [gap automatic-port-dimension]
                         #:width [width automatic-port-dimension]
                         #:depth [depth automatic-port-dimension]
                         #:anchor [anchor 'center]
                         #:priority [priority #f]
                         #:precedence [precedence #f])
  (define local-direction (hash-ref direction-components direction #f))
  (unless local-direction
    (raise-argument-error
     'add-lumped-port
     "(or/c 'forward 'forwards 'back 'backward 'backwards 'left 'right 'up 'down)"
     direction))
  (when requested-name (geometry-name 'add-lumped-port requested-name))
  (positive-real 'add-lumped-port impedance "reference impedance")
  (define effective-priority
    (effective-precedence 'add-lumped-port priority precedence))
  (define scale-factor (current-geometry-scale))
  (define (effective-dimension value default description positive?)
    (if (eq? value automatic-port-dimension)
        default
        (begin
          ((if positive? positive-real nonnegative-real)
           'add-lumped-port value description)
          (* scale-factor value))))
  (define effective-gap
    (effective-dimension gap (/ (model-wavelength) 1000) "gap" #t))
  (define effective-width
    (effective-dimension width (/ (model-wavelength) 1000) "width" #f))
  (define effective-depth
    (effective-dimension depth (/ (model-wavelength) 1000) "depth" #f))
  (define scene (current-solid-scene))
  (define name
    (if requested-name
        (effective-feature-name 'add-lumped-port requested-name 'port scene)
        (fresh-port-name scene)))
  (define placement (current-turtle-affine-transform 'add-lumped-port))
  (define transverse (hash-ref transverse-components direction))
  (define world-direction (transform-vector placement local-direction))
  (define center
    (anchored-feature-center
     'add-lumped-port anchor
     (transform-point placement '(0 0 0))
     world-direction effective-gap))
  (define port
    (lumped-port
     name impedance
     center world-direction
     (transform-vector placement (first transverse))
     (transform-vector placement (second transverse))
     effective-gap effective-width effective-depth
     effective-priority placement))
  (set-solid-scene-ports!
   scene (append (solid-scene-ports scene) (list port)))
  port)

(define (add-lumped-element direction
                            #:name [requested-name #f]
                            #:resistance [resistance #f]
                            #:inductance [inductance #f]
                            #:capacitance [capacitance #f]
                            #:topology [topology #f]
                            #:caps [caps #t]
                            #:gap gap
                            #:width width
                            #:depth depth
                            #:anchor [anchor 'center]
                            #:priority [priority #f]
                            #:precedence [precedence #f])
  (define local-direction (hash-ref direction-components direction #f))
  (unless local-direction
    (raise-argument-error 'add-lumped-element "turtle direction" direction))
  (define electrical-values (filter values (list resistance inductance capacitance)))
  (when (null? electrical-values)
    (raise-arguments-error 'add-lumped-element
                           "at least one electrical value is required"
                           "resistance" resistance
                           "inductance" inductance
                           "capacitance" capacitance))
  (for ([value (in-list electrical-values)])
    (positive-real 'add-lumped-element value "electrical value"))
  (unless (or (not topology) (memq topology '(series parallel)))
    (raise-argument-error 'add-lumped-element
                          "(or/c #f 'series 'parallel)" topology))
  (when (and (> (length electrical-values) 1) (not topology))
    (raise-arguments-error 'add-lumped-element
                           "topology is required when multiple electrical values are present"
                           "topology" topology))
  (unless (boolean? caps)
    (raise-argument-error 'add-lumped-element "boolean?" caps))
  (positive-real 'add-lumped-element gap "gap")
  (positive-real 'add-lumped-element width "width")
  (positive-real 'add-lumped-element depth "depth")
  (define scene (current-solid-scene))
  (define name
    (effective-feature-name 'add-lumped-element requested-name 'element scene))
  (define effective-priority
    (effective-precedence 'add-lumped-element priority precedence))
  (define scale-factor (current-geometry-scale))
  (define placement (current-turtle-affine-transform 'add-lumped-element))
  (define transverse (hash-ref transverse-components direction))
  (define world-direction (transform-vector placement local-direction))
  (define effective-gap (* scale-factor gap))
  (define center
    (anchored-feature-center
     'add-lumped-element anchor
     (transform-point placement '(0 0 0))
     world-direction effective-gap))
  (define component
    (lumped-component
     name resistance inductance capacitance (or topology 'parallel) caps
     center world-direction
     (transform-vector placement (first transverse))
     (transform-vector placement (second transverse))
     effective-gap (* scale-factor width) (* scale-factor depth)
     effective-priority placement))
  (set-solid-scene-components!
   scene (append (solid-scene-components scene) (list component)))
  component)

;; The backend-neutral lumped-element DSL calls this hook only when transverse
;; dimensions were supplied.  Wire-only declarations therefore remain usable
;; on installations without Manifold.
(current-solid-lumped-element-handler add-lumped-element)

(define (point+scaled point vector scale)
  (point3 (+ (point3-x point) (* scale (point3-x vector)))
          (+ (point3-y point) (* scale (point3-y vector)))
          (+ (point3-z point) (* scale (point3-z vector)))))

(define (lumped-port-start port)
  (unless (lumped-port? port)
    (raise-argument-error 'lumped-port-start "lumped-port?" port))
  (point+scaled (lumped-port-center port)
                (lumped-port-direction port)
                (- (/ (lumped-port-gap port) 2))))

(define (lumped-port-stop port)
  (unless (lumped-port? port)
    (raise-argument-error 'lumped-port-stop "lumped-port?" port))
  (point+scaled (lumped-port-center port)
                (lumped-port-direction port)
                (/ (lumped-port-gap port) 2)))

(define (body-overlap? first-body second-body)
  (define overlap
    (m:intersection (solid-body-solid first-body)
                    (solid-body-solid second-body)))
  (dynamic-wind
    void
    (lambda ()
      (and (not (m:solid-empty? overlap))
           (positive? (m:solid-volume overlap))))
    (lambda () (m:solid-close! overlap))))

(define (point-axis point axis)
  (case axis
    [(0) (point3-x point)]
    [(1) (point3-y point)]
    [else (point3-z point)]))

(define (sheet-bounds sheet)
  (define all-points (append* (planar-sheet-polygons sheet)))
  (values
   (for/list ([axis (in-range 3)])
     (apply min (map (lambda (point) (point-axis point axis))
                     all-points)))
   (for/list ([axis (in-range 3)])
     (apply max (map (lambda (point) (point-axis point axis))
                     all-points)))))

(define (body-bounds body)
  (define-values (minimum maximum) (m:solid-bounds (solid-body-solid body)))
  (values (list (m:point3-x minimum) (m:point3-y minimum) (m:point3-z minimum))
          (list (m:point3-x maximum) (m:point3-y maximum) (m:point3-z maximum))))

(define (bounds-touch? first-minimum first-maximum second-minimum second-maximum)
  (for/and ([first-low (in-list first-minimum)]
            [first-high (in-list first-maximum)]
            [second-low (in-list second-minimum)]
            [second-high (in-list second-maximum)])
    (and (<= first-low second-high) (<= second-low first-high))))

(define (different-material-overlap! first-kind first-name first-material first-priority
                                     second-kind second-name second-material second-priority)
  (unless (or (equal? first-material second-material)
              (and first-priority second-priority
                   (not (= first-priority second-priority))))
    (raise-arguments-error
     'validate-solid-scene!
     "overlapping geometry with different materials needs distinct explicit priorities"
     (format "first ~a" first-kind) first-name
     "first priority" first-priority
     (format "second ~a" second-kind) second-name
     "second priority" second-priority)))

(define (validate-solid-scene! [scene (current-solid-scene)])
  (for* ([first-body (in-list (solid-scene-bodies scene))]
         [second-body (in-list (solid-scene-bodies scene))]
         #:when (< (index-of (solid-scene-bodies scene) first-body eq?)
                   (index-of (solid-scene-bodies scene) second-body eq?))
         #:unless (equal? (solid-body-material first-body)
                          (solid-body-material second-body)))
    (when (body-overlap? first-body second-body)
      (different-material-overlap!
       "body" (solid-body-name first-body) (solid-body-material first-body)
       (solid-body-priority first-body)
       "body" (solid-body-name second-body) (solid-body-material second-body)
       (solid-body-priority second-body))))
  ;; Manifold gives an exact volume/volume test above. Zero-thickness sheets
  ;; use conservative inclusive bounds: when unlike materials touch, the
  ;; programmer must state which CSXCAD primitive wins at that interface.
  (for* ([sheet (in-list (solid-scene-sheets scene))]
         [body (in-list (solid-scene-bodies scene))])
    (define-values (sheet-minimum sheet-maximum) (sheet-bounds sheet))
    (define-values (body-minimum body-maximum) (body-bounds body))
    (when (bounds-touch? sheet-minimum sheet-maximum body-minimum body-maximum)
      (different-material-overlap!
       "sheet" (planar-sheet-name sheet) (planar-sheet-material sheet)
       (planar-sheet-priority sheet)
       "body" (solid-body-name body) (solid-body-material body)
       (solid-body-priority body))))
  (for* ([first-sheet (in-list (solid-scene-sheets scene))]
         [second-sheet (in-list (solid-scene-sheets scene))]
         #:when (< (index-of (solid-scene-sheets scene) first-sheet eq?)
                   (index-of (solid-scene-sheets scene) second-sheet eq?)))
    (define-values (first-minimum first-maximum) (sheet-bounds first-sheet))
    (define-values (second-minimum second-maximum) (sheet-bounds second-sheet))
    (when (bounds-touch? first-minimum first-maximum second-minimum second-maximum)
      (different-material-overlap!
       "sheet" (planar-sheet-name first-sheet) (planar-sheet-material first-sheet)
       (planar-sheet-priority first-sheet)
       "sheet" (planar-sheet-name second-sheet) (planar-sheet-material second-sheet)
       (planar-sheet-priority second-sheet))))
  (void))

(define (clear-bodies)
  (for ([body (in-list (solid-scene-bodies (current-solid-scene)))])
    (define solid (solid-body-solid body))
    (unless (m:solid-closed? solid) (m:solid-close! solid)))
  ;; Ports and sheets are subordinate to the physical bodies they touch.
  (current-solid-scene (solid-scene '() '() '() '()))
  (clear-model-cuboids)
  (clear-mesh-constraints)
  (void))

(register-model-reset-hook! clear-bodies)
