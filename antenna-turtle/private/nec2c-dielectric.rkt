#lang racket/base

(require racket/list
         racket/match
         racket/math
         racket/string
         "core.rkt"
         "material.rkt"
         "export-common.rkt")

(provide
 (struct-out model-cuboid)
 (struct-out nec2c-dielectric-mesh-spec)
 (struct-out nec2c-dielectric-auto-mesh-spec)
 (struct-out nec2c-dielectric-plan)
 add-model-cuboid
 model-cuboids
 clear-model-cuboids
 current-nec2c-dielectric-mesh
 model-cuboid-bounds
 plan-nec2c-dielectric
 write-nec2c-dielectric-resource)

;; Placement is a captured, scaled row-major 3x4 local-to-world transform.
;; Bounds remain derived data so export and visualization share one source of
;; truth and can apply model-height at their respective boundaries.
(struct model-cuboid
  (name material size anchor placement declaration-index)
  #:transparent)

(define (finite-real? value)
  (and (real? value) (rational? value)))

(struct nec2c-dielectric-mesh-spec (max-kh max-cells max-aspect)
  #:transparent
  #:guard
  (lambda (max-kh max-cells max-aspect who)
    (unless (and (finite-real? max-kh) (positive? max-kh) (<= max-kh 1))
      (raise-argument-error who "finite-real-in (0, 1]" max-kh))
    (unless (exact-positive-integer? max-cells)
      (raise-argument-error who "exact-positive-integer?" max-cells))
    (unless (and (finite-real? max-aspect) (>= max-aspect 1))
      (raise-argument-error who "finite-real-at-least-1?" max-aspect))
    (values max-kh max-cells max-aspect)))

(struct nec2c-dielectric-auto-mesh-spec
  (max-kh max-cells snap-wavelength-divisor snap-feature-divisor)
  #:transparent
  #:guard
  (lambda (max-kh max-cells wavelength-divisor feature-divisor who)
    (unless (and (finite-real? max-kh) (positive? max-kh) (<= max-kh 1))
      (raise-argument-error who "finite-real-in (0, 1]" max-kh))
    (unless (exact-positive-integer? max-cells)
      (raise-argument-error who "exact-positive-integer?" max-cells))
    (unless (and (finite-real? wavelength-divisor) (>= wavelength-divisor 1))
      (raise-argument-error who "finite-real-at-least-1?" wavelength-divisor))
    (unless (and (finite-real? feature-divisor) (>= feature-divisor 1))
      (raise-argument-error who "finite-real-at-least-1?" feature-divisor))
    (values max-kh max-cells wavelength-divisor feature-divisor)))

(struct nec2c-dielectric-plan
  (mesh adjusted-boxes pitch cell-count minimum-wavelength snap-limit
        maximum-adjustment minimum-clearance)
  #:transparent)

(define current-model-cuboids (make-parameter '()))
(define current-nec2c-dielectric-mesh
  (make-parameter (nec2c-dielectric-mesh-spec 0.5 1000 2.0)))

(define (clear-model-cuboids)
  (current-model-cuboids '())
  (current-nec2c-dielectric-mesh
   (nec2c-dielectric-mesh-spec 0.5 1000 2.0))
  (void))

(register-model-reset-hook! clear-model-cuboids)

(define (validate-name who name)
  (unless (or (symbol? name)
              (and (string? name)
                   (not (string=? name ""))
                   (not (regexp-match? #rx"[\\r\\n]" name))))
    (raise-argument-error who
                          "(or/c symbol? non-empty-single-line-string?)"
                          name))
  name)

(define (validate-size who size)
  (define normalized
    (cond
      [(and (list? size) (= (length size) 3)) size]
      [(and (vector? size) (= (vector-length size) 3)) (vector->list size)]
      [else #f]))
  (unless normalized
    (raise-argument-error who "(list/c positive-real? positive-real? positive-real?)" size))
  (for ([dimension (in-list normalized)])
    (unless (and (finite-real? dimension) (positive? dimension))
      (raise-argument-error who
                            "(list/c positive-finite-real? positive-finite-real? positive-finite-real?)"
                            size)))
  normalized)

(define (validate-material who material)
  (unless (and (em-material? material)
               (eq? (em-material-kind material) 'dielectric))
    (raise-argument-error who "dielectric em-material?" material))
  (unless (= (em-material-relative-permeability material) 1)
    (raise-arguments-error
     who "NEC2C dielectric revision 1 requires relative permeability 1"
     "material" material))
  material)

(define (scaled-placement who)
  (define scale-factor (current-geometry-scale))
  (for/list ([row (in-list (current-turtle-affine-transform who))])
    (append (for/list ([coefficient (in-list (take row 3))])
              (* scale-factor coefficient))
            (list (fourth row)))))

(define alignment-tolerance 1e-10)

(define (axis-aligned-placement? placement)
  (define linear (for/list ([row (in-list placement)]) (take row 3)))
  (define columns (apply map list linear))
  (define occupied-rows
    (for/list ([column (in-list columns)])
      (define nonzero
        (for/list ([value (in-list column)] [row (in-naturals)]
                   #:when (> (abs value) alignment-tolerance))
          row))
      (and (= (length nonzero) 1) (car nonzero))))
  (and (andmap exact-nonnegative-integer? occupied-rows)
       (= (length (remove-duplicates occupied-rows)) 3)))

(define (add-model-cuboid name material size #:anchor [anchor 'center])
  (validate-name 'add-model-cuboid name)
  (unless (em-material? material)
    (raise-argument-error 'add-model-cuboid "em-material?" material))
  (define normalized-size (validate-size 'add-model-cuboid size))
  (define cuboids (current-model-cuboids))
  (when (for/or ([cuboid (in-list cuboids)])
          (equal? name (model-cuboid-name cuboid)))
    (raise-arguments-error
     'add-model-cuboid
     "explicit cuboid names must be unique"
     "name" name))
  (define cuboid
    (model-cuboid name material normalized-size anchor
                  (scaled-placement 'add-model-cuboid)
                  (add1 (length cuboids))))
  (current-model-cuboids (append cuboids (list cuboid)))
  cuboid)

(define (model-cuboids) (current-model-cuboids))

(define anchor-axis
  (hash 'front   (cons 0 'maximum)
        'forward (cons 0 'maximum)
        'back    (cons 0 'minimum)
        'left    (cons 1 'maximum)
        'right   (cons 1 'minimum)
        'top     (cons 2 'maximum)
        'up      (cons 2 'maximum)
        'bottom  (cons 2 'minimum)
        'down    (cons 2 'minimum)))

(define (anchor-point who size anchor)
  (match-define (list x y z) size)
  (define minimum (list (- (/ x 2)) (- (/ y 2)) (- (/ z 2))))
  (define maximum (list (/ x 2) (/ y 2) (/ z 2)))
  (cond
    [(memq anchor '(origin center)) '(0 0 0)]
    [(or (and (list? anchor) (= (length anchor) 3) (andmap finite-real? anchor))
         (and (vector? anchor) (= (vector-length anchor) 3)
              (andmap finite-real? (vector->list anchor))))
     (if (vector? anchor) (vector->list anchor) anchor)]
    [else
     (define directions (if (symbol? anchor) (list anchor) anchor))
     (unless (and (list? directions) (pair? directions) (andmap symbol? directions))
       (raise-argument-error
        who "anchor direction, list of orthogonal directions, or local point" anchor))
     (define selected (make-hasheq))
     (for ([direction (in-list directions)])
       (define selection (hash-ref anchor-axis direction #f))
       (unless selection
         (raise-arguments-error who "unknown anchor direction" "direction" direction))
       (define axis (car selection))
       (when (hash-has-key? selected axis)
         (raise-arguments-error
          who "anchor directions must select at most one face per axis"
          "anchor" anchor))
       (hash-set! selected axis (cdr selection)))
     (for/list ([axis (in-range 3)])
       (case (hash-ref selected axis 'center)
         [(minimum) (list-ref minimum axis)]
         [(maximum) (list-ref maximum axis)]
         [else 0]))]))

(define (anchor-minimum size anchor)
  (match-define (list x y z) size)
  (define source-minimum (list (- (/ x 2)) (- (/ y 2)) (- (/ z 2))))
  (map - source-minimum (anchor-point 'model-cuboid-bounds size anchor)))

(define (transform-point placement point)
  (for/list ([row (in-list placement)])
    (+ (fourth row)
       (for/sum ([coefficient (in-list (take row 3))]
                 [coordinate (in-list point)])
         (* coefficient coordinate)))))

(define (model-cuboid-bounds cuboid)
  (unless (model-cuboid? cuboid)
    (raise-argument-error 'model-cuboid-bounds "model-cuboid?" cuboid))
  (define size (model-cuboid-size cuboid))
  (define minimum (anchor-minimum size (model-cuboid-anchor cuboid)))
  (define maximum (map + minimum size))
  (define corners
    (for*/list ([x (in-list (list (first minimum) (first maximum)))]
                [y (in-list (list (second minimum) (second maximum)))]
                [z (in-list (list (third minimum) (third maximum)))])
      (transform-point (model-cuboid-placement cuboid) (list x y z))))
  (values (for/list ([axis (in-range 3)])
            (apply min (map (lambda (point) (list-ref point axis)) corners)))
          (for/list ([axis (in-range 3)])
            (apply max (map (lambda (point) (list-ref point axis)) corners)))))

(define (dielectric-cuboids cuboids)
  (filter (lambda (cuboid)
            (eq? (em-material-kind (model-cuboid-material cuboid)) 'dielectric))
          cuboids))

(define (material-id-table volumes)
  (define result (make-hash))
  (for ([volume (in-list volumes)])
    (define material (model-cuboid-material volume))
    (unless (hash-has-key? result material)
      (hash-set! result material (add1 (hash-count result)))))
  result)

(define (ordered-materials volumes)
  (remove-duplicates
   (map model-cuboid-material volumes)
   equal?))

(define (material-sigma who material reference-frequency-mhz)
  (define loss (em-material-loss-spec material))
  (cond
    [(not loss) (em-material-electric-conductivity material)]
    [(eq? (material-loss-kind loss) 'narrow)
     (define frequency
       (if (eq? (material-loss-reference-frequency loss) 'model)
           reference-frequency-mhz
           (material-loss-reference-frequency loss)))
     (* 2 pi (* frequency 1e6) 8.8541878128e-12
        (em-material-relative-permittivity material)
        (material-loss-value loss))]
    [else
     (raise-arguments-error
      who
      "NEC2C dielectric revision 1 supports only constant conductivity or narrow loss tangent"
      "material" material
      "loss kind" (material-loss-kind loss))]))

(define vacuum-permittivity 8.8541878128e-12)
(define speed-of-light 299792458.0)

(define (material-mesh-index who material frequency-mhz)
  (validate-material who material)
  (define er (exact->inexact (em-material-relative-permittivity material)))
  (define sigma (exact->inexact (material-sigma who material frequency-mhz)))
  (define omega (* 2.0 pi frequency-mhz 1e6))
  ;; This is the same lossy-material mesh index used by NEC2C-N5HXR.
  (sqrt (sqrt (+ (* er er)
                 (sqr (/ sigma (* omega vacuum-permittivity)))))))

(define (point3->list point)
  (list (point3-x point) (point3-y point) (point3-z point)))

;; The squared segment-to-box distance is piecewise quadratic in t.  Checking
;; each interval endpoint and stationary point gives the exact minimum without
;; sampling artifacts for wires that run parallel to a dielectric face.
(define (segment-box-distance start end minimum maximum)
  (define p0 (map exact->inexact (point3->list start)))
  (define p1 (map exact->inexact (point3->list end)))
  (define lo (map exact->inexact minimum))
  (define hi (map exact->inexact maximum))
  (define delta (map - p1 p0))
  (define breakpoints
    (sort
     (remove-duplicates
      (append
       '(0.0 1.0)
       (for*/list ([axis (in-range 3)]
                   [face (in-list (list (list-ref lo axis)
                                        (list-ref hi axis)))]
                   #:when (not (zero? (list-ref delta axis)))
                   [t (in-value (/ (- face (list-ref p0 axis))
                                   (list-ref delta axis)))]
                   #:when (and (> t 0.0) (< t 1.0)))
         t))
      (lambda (a b) (< (abs (- a b)) 1e-14)))
     <))
  (define (quadratic-at t)
    (for/sum ([origin (in-list p0)] [step (in-list delta)]
              [lower (in-list lo)] [upper (in-list hi)])
      (define value (+ origin (* t step)))
      (cond [(< value lower) (sqr (- lower value))]
            [(> value upper) (sqr (- value upper))]
            [else 0.0])))
  (define candidates breakpoints)
  (for ([left (in-list breakpoints)] [right (in-list (rest breakpoints))])
    (define midpoint (/ (+ left right) 2.0))
    (define-values (a b)
      (for/fold ([a 0.0] [b 0.0])
                ([origin (in-list p0)] [step (in-list delta)]
                 [lower (in-list lo)] [upper (in-list hi)])
        (define value (+ origin (* midpoint step)))
        (cond
          [(< value lower)
           (values (+ a (* step step))
                   (+ b (* 2.0 step (- origin lower))))]
          [(> value upper)
           (values (+ a (* step step))
                   (+ b (* 2.0 step (- origin upper))))]
          [else (values a b)])))
    (when (positive? a)
      (define stationary (/ (- b) (* 2.0 a)))
      (when (and (> stationary left) (< stationary right))
        (set! candidates (cons stationary candidates)))))
  (sqrt (apply min (map quadratic-at candidates))))

(define (box-wire-clearance minimum maximum)
  (for/fold ([minimum-gap +inf.0]) ([edge (in-list (model-edges))])
    (define radius (/ (wire-edge-diameter edge) 2.0))
    (min minimum-gap
         (- (segment-box-distance
             (vertex-point (wire-edge-start edge))
             (vertex-point (wire-edge-end edge))
             minimum maximum)
            radius))))

(define (maximum-processed-segment-length)
  (for/fold ([longest 0.0]) ([edge (in-list (model-edges))])
    (max longest (/ (edge-length edge) (edge-segment-count edge)))))

(struct automatic-candidate
  (pitch counts minimum maximum cells adjustment clearance)
  #:transparent)

(define (candidate-better? candidate current)
  (or (not current)
      (< (automatic-candidate-cells candidate)
         (automatic-candidate-cells current))
      (and (= (automatic-candidate-cells candidate)
              (automatic-candidate-cells current))
           (< (automatic-candidate-adjustment candidate)
              (automatic-candidate-adjustment current)))
      (and (= (automatic-candidate-cells candidate)
              (automatic-candidate-cells current))
           (= (automatic-candidate-adjustment candidate)
              (automatic-candidate-adjustment current))
           (> (automatic-candidate-pitch candidate)
              (automatic-candidate-pitch current)))))

(define (plan-nec2c-dielectric
         #:cuboids [cuboids (model-cuboids)]
         #:frequency [frequency-mhz (model-frequency)]
         #:mesh [mesh (current-nec2c-dielectric-mesh)])
  (define who 'plan-nec2c-dielectric)
  (define enabled (dielectric-cuboids cuboids))
  (unless (nec2c-dielectric-auto-mesh-spec? mesh)
    (raise-argument-error who "nec2c-dielectric-auto-mesh-spec?" mesh))
  (unless (= (length enabled) 1)
    (raise-arguments-error
     who
     "automatic dielectric mesh revision 1 requires exactly one cuboid; use a manual mesh for multi-volume models"
     "dielectric cuboids" (length enabled)))
  (unless (and (finite-real? frequency-mhz) (positive? frequency-mhz))
    (raise-argument-error who "positive-finite-real?" frequency-mhz))
  (define volume (first enabled))
  (unless (axis-aligned-placement? (model-cuboid-placement volume))
    (raise-arguments-error
     who "automatic dielectric meshing requires a globally axis-aligned cuboid"
     "cuboid" (model-cuboid-name volume)))
  (define material (validate-material who (model-cuboid-material volume)))
  (define mesh-index (material-mesh-index who material frequency-mhz))
  (define k0 (/ (* 2.0 pi frequency-mhz 1e6) speed-of-light))
  (define minimum-wavelength (/ (* 2.0 pi) (* k0 mesh-index)))
  (define-values (minimum maximum) (model-cuboid-bounds volume))
  (define lengths (map - maximum minimum))
  (define snap-limit
    (min (/ minimum-wavelength
            (nec2c-dielectric-auto-mesh-spec-snap-wavelength-divisor mesh))
         (/ (apply min lengths)
            (nec2c-dielectric-auto-mesh-spec-snap-feature-divisor mesh))))
  (define maximum-pitch
    (/ (nec2c-dielectric-auto-mesh-spec-max-kh mesh) (* k0 mesh-index)))
  (define maximum-cells (nec2c-dielectric-auto-mesh-spec-max-cells mesh))
  (define segment-length (maximum-processed-segment-length))
  (define center (map (lambda (lo hi) (/ (+ lo hi) 2.0)) minimum maximum))
  (define best #f)
  ;; Let each axis supply an exact pitch in turn.  This discovers a compact
  ;; common lattice (for example 100x2x2) without a floating-point ratio test.
  (for ([base-axis (in-range 3)])
    (define base-length (list-ref lengths base-axis))
    (define first-count (max 1 (inexact->exact (ceiling (/ base-length maximum-pitch)))))
    (for ([base-count (in-range first-count (add1 maximum-cells))])
      (define pitch (/ base-length base-count))
      (define counts
        (for/list ([length (in-list lengths)])
          (max 1 (inexact->exact (round (/ length pitch))))))
      (define cells (apply * counts))
      (when (<= cells maximum-cells)
        (define adjusted-lengths (map (lambda (count) (* count pitch)) counts))
        (define adjustments
          (map (lambda (old new) (/ (abs (- new old)) 2.0))
               lengths adjusted-lengths))
        (when (<= (apply max adjustments) snap-limit)
          (define adjusted-minimum
            (map (lambda (c length) (- c (/ length 2.0))) center adjusted-lengths))
          (define adjusted-maximum
            (map (lambda (c length) (+ c (/ length 2.0))) center adjusted-lengths))
          (define clearance (box-wire-clearance adjusted-minimum adjusted-maximum))
          (when (and (positive? clearance)
                     (<= pitch clearance)
                     (<= segment-length clearance))
            (define candidate
              (automatic-candidate pitch counts adjusted-minimum adjusted-maximum
                                   cells (apply max adjustments) clearance))
            (when (candidate-better? candidate best)
              (set! best candidate)))))))
  (unless best
    (raise-arguments-error
     who
     "automatic mesh optimization cannot accommodate the electrical resolution, cell limit, cubic lattice, bounded geometry snap, and conductor-clearance constraints"
     "cuboid" (model-cuboid-name volume)
     "minimum wavelength (m)" minimum-wavelength
     "maximum face movement (m)" snap-limit
     "original conductor clearance (m)" (box-wire-clearance minimum maximum)
     "processed wire segment length (m)" segment-length
     "maximum cells" maximum-cells
     "suggestion" "increase max-cells, refine the antenna wire segmentation, move the dielectric, or use a manual mesh"))
  (define pitch (automatic-candidate-pitch best))
  ;; Keep an integer edge/pitch ratio after material and mesh values are
  ;; independently rounded for the resource file.  The pitch itself remains
  ;; the controlling resolution; this guard only prevents CEIL from adding a
  ;; spurious extra division.
  (define concrete-kh
    (min (nec2c-dielectric-auto-mesh-spec-max-kh mesh)
         (* k0 mesh-index pitch (+ 1.0 1e-8))))
  (nec2c-dielectric-plan
   ;; Exact unity makes the mesher refine indefinitely when independently
   ;; serialized bounds differ by a last bit.  This allowance is half the
   ;; FFT solver's 1e-10 uniform-cube tolerance.
   (nec2c-dielectric-mesh-spec concrete-kh maximum-cells 1.00000000005)
   (list (list volume
               (automatic-candidate-minimum best)
               (automatic-candidate-maximum best)
               (automatic-candidate-counts best)))
   pitch
   (automatic-candidate-cells best)
   minimum-wavelength
   snap-limit
   (automatic-candidate-adjustment best)
   (automatic-candidate-clearance best)))

(define (write-nec2c-dielectric-resource out
                                          #:cuboids [cuboids (model-cuboids)]
                                          #:frequency [frequency-mhz (model-frequency)]
                                          #:mesh-frequency [mesh-frequency-mhz frequency-mhz]
                                          #:mesh [mesh (current-nec2c-dielectric-mesh)])
  (define who 'write-nec2c-dielectric-resource)
  (define enabled (dielectric-cuboids cuboids))
  (when (null? enabled)
    (raise-arguments-error who "at least one enabled dielectric volume is required"))
  (define plan
    (and (nec2c-dielectric-auto-mesh-spec? mesh)
         (plan-nec2c-dielectric #:cuboids cuboids
                                #:frequency mesh-frequency-mhz
                                #:mesh mesh)))
  (define concrete-mesh
    (if plan (nec2c-dielectric-plan-mesh plan) mesh))
  (define planned-boxes
    (and plan (nec2c-dielectric-plan-adjusted-boxes plan)))
  (define material-ids (material-id-table enabled))
  (displayln "NEC2C-DIELECTRIC 2" out)
  (when plan
    (fprintf out "# AUTO_MESH PITCH ~a CELLS ~a SNAP ~a CLEARANCE ~a\n"
             (roundtrip-coordinate-string who (nec2c-dielectric-plan-pitch plan))
             (nec2c-dielectric-plan-cell-count plan)
             (roundtrip-coordinate-string
              who (nec2c-dielectric-plan-maximum-adjustment plan))
             (let ([clearance (nec2c-dielectric-plan-minimum-clearance plan)])
               (if (finite-real? clearance)
                   (roundtrip-coordinate-string who clearance)
                   "none"))))
  (for ([material (in-list (ordered-materials enabled))])
    (define id (hash-ref material-ids material))
    (define sigma (material-sigma who material frequency-mhz))
    (fprintf out "MATERIAL ~a ER ~a" id
             (coordinate-string who (em-material-relative-permittivity material)))
    (when (positive? sigma)
      (fprintf out " SIGMA ~a" (coordinate-string who sigma)))
    (newline out))
  (for ([volume (in-list enabled)] [region-id (in-naturals 1)])
    (fprintf out "# REGION ~a ~a\n" region-id
             (model-cuboid-name volume))
    (fprintf out "REGION ~a MATERIAL ~a\n" region-id
             (hash-ref material-ids (model-cuboid-material volume)))
    (unless (axis-aligned-placement? (model-cuboid-placement volume))
      (raise-arguments-error
       who
       "NEC2C-N5HXR dielectric cuboids must align with the global X, Y, and Z axes"
       "cuboid" (model-cuboid-name volume)
       "placement" (model-cuboid-placement volume)))
    (validate-material who (model-cuboid-material volume))
    (define planned-box
      (and planned-boxes
           (for/first ([box (in-list planned-boxes)]
                       #:when (eq? (first box) volume))
             box)))
    (define-values (minimum maximum)
      (if planned-box
          (values (second planned-box) (third planned-box))
          (model-cuboid-bounds volume)))
    (define adjusted-minimum
      (list (first minimum) (second minimum) (+ (third minimum) (model-height))))
    (define adjusted-maximum
      (list (first maximum) (second maximum) (+ (third maximum) (model-height))))
    (fprintf out "BOX ~a ~a\n" region-id
             (string-join
              (map (lambda (value) (roundtrip-coordinate-string who value))
                   (append adjusted-minimum adjusted-maximum))
              " ")))
  (fprintf out "MESH MAX_KH ~a MAX_CELLS ~a MAX_ASPECT ~a\n"
           (coordinate-string who (nec2c-dielectric-mesh-spec-max-kh concrete-mesh))
           (nec2c-dielectric-mesh-spec-max-cells concrete-mesh)
           (coordinate-string who (nec2c-dielectric-mesh-spec-max-aspect concrete-mesh)))
  (displayln "END" out))
