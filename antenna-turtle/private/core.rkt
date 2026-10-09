#lang racket/base

(require racket/list
         racket/math)

(provide
 ;; Exact length constants, in meters.
 meter meters centimeter centimeters millimeter millimeters
 inch inches foot feet

 ;; Antenna arithmetic.
 frequency->wavelength wavelength->frequency model-wavelength
 paraboloid cylinder dome bowl catenary
 span frequency-retuning-scale

 ;; Model data, useful to tooling and tests.
 (struct-out point3)
 (struct-out vertex)
 (struct-out feed-spec)
 (struct-out ground-spec)
 (struct-out wire-edge)
 wire-edge-feed? wire-edge-feed-location wire-edge-feed-name
 wire-edge-feed-amplitude wire-edge-feed-phase
 (struct-out antenna-model)
 current-antenna-model
 model-vertices
 model-edges
 wire-used

 ;; Extension support. These are consumed by geometry backends rather than
 ;; intended as surface DSL operations.
 register-model-reset-hook!
 current-turtle-affine-transform

 ;; Model settings.
 clear-wires
 reset-model!
 validate-model!
 model-title
 model-impedance
 model-ground
 model-grounded?
 model-height
 real-ground
 maximum-segment-length
 snap-length
 model-frequency
 mmana-frequency

 ;; Turtle operations.
 wire-off wire-on call-with-wire call-with-points call-with-scale call-from-here
 call-with-warp call-with-surface call-with-reflection call-with-radial-repeat
 radial-iterations-value
 ;; Compatibility names retained for existing models.
 pen-up pen-down call-with-pen call-with-push
 forward forwards back backward backwards
 move-local move-vector-local move-vector-local-steps
 point-vector-local spread-local move-nearest
 here goto
 turn-x turn-y turn-z turn-axis
 scale scale-all
 wire-diameter
 push pop
 make-feed-spec mark-feed feed

 ;; some utility functions
 half
 
 ;; Exporter support.
 edge-length
 edge-segment-count
 current-wire-diameter
 current-position)

;; Unit constants are exact rationals so dimensional arithmetic remains exact
;; until a rotation or export actually requires an inexact value.
(define meter 1)
(define meters meter)
(define centimeter 1/100)
(define centimeters centimeter)
(define millimeter 1/1000)
(define millimeters millimeter)
(define inch 127/5000)
(define inches inch)
(define foot (* 12 inch))
(define feet foot)

;; The SI definition is exact. Public frequency values are in MHz to match
;; model-frequency, while public wavelength values are in metres to match the
;; rest of Antenna Turtle's physical-length API.
(define speed-of-light-metres-per-second 299792458)
(define hertz-per-megahertz 1000000)

(struct point3 (x y z) #:transparent)
(struct vertex (id point) #:transparent)
(struct feed-spec (location name amplitude phase) #:transparent)
(struct ground-spec (kind relative-permittivity conductivity) #:transparent)
(struct wire-edge (id start end diameter feed-info) #:transparent)
(struct antenna-model (vertices edges) #:mutable #:transparent)

;; An orientation is a row-major 3x3 local-to-global matrix.
(struct turtle-state
  (position orientation pen-down? movement-scale diameter-scale
            base-diameter previous-source point-anchor)
  #:transparent)

;; A warp maps coordinates expressed in the fixed local frame captured when
;; its scope begins. Turtle state remains in ordinary logical/global space;
;; only points crossing the model-geometry boundary are mapped.
(struct coordinate-warp (origin orientation mapper) #:transparent)

(define identity-matrix
  '((1 0 0)
    (0 1 0)
    (0 0 1)))

(define (initial-state [base-diameter millimeter])
  (turtle-state (point3 0 0 0)
                identity-matrix
                #f
                1
                1
                base-diameter
                #f
                #f))

(define current-antenna-model
  (make-parameter (antenna-model '() '())))
(define current-turtle-state (make-parameter (initial-state)))
(define current-turtle-stack (make-parameter '()))
(define pending-feed-location (make-parameter #f))
(define current-coordinate-warp (make-parameter #f))
(define current-radial-iterations (make-parameter '()))
(define model-reset-hooks '())

(define (register-model-reset-hook! hook)
  (unless (and (procedure? hook) (procedure-arity-includes? hook 0))
    (raise-argument-error
     'register-model-reset-hook! "(procedure-arity-includes/c 0)" hook))
  (unless (memq hook model-reset-hooks)
    (set! model-reset-hooks (append model-reset-hooks (list hook))))
  (void))

;; Model settings retain the same zero/one-argument interface as ordinary
;; Racket parameters. Maximum segment length stores #f internally to mean a
;; dynamic one-twentieth-wavelength default.
(define model-title (make-parameter "Turtle Antenna"))
(define model-impedance
  (make-parameter
   50
   (lambda (value)
     (ensure-positive-real 'model-impedance value "reference impedance")
     value)))
(define no-ground (ground-spec 'none #f #f))
(define perfect-ground (ground-spec 'perfect #f #f))
(define average-real-ground (ground-spec 'real 13 1/200))

(define (real-ground relative-permittivity conductivity)
  (ensure-positive-real
   'real-ground relative-permittivity "relative permittivity")
  (ensure-real 'real-ground conductivity "conductivity in S/m")
  (when (negative? conductivity)
    (raise-argument-error 'real-ground "nonnegative-real?" conductivity))
  (ground-spec 'real relative-permittivity conductivity))

;; The direct setter accepts the same convenient symbolic presets as the DSL;
;; the getter returns a transparent ground-spec for tooling and exporters.
(define model-ground
  (make-parameter
   no-ground
   (lambda (value)
     (cond
       [(eq? value 'none) no-ground]
       [(eq? value 'perfect) perfect-ground]
       [(eq? value 'real) average-real-ground]
       [(ground-spec? value)
        (case (ground-spec-kind value)
          [(none) no-ground]
          [(perfect) perfect-ground]
          [(real)
           (real-ground (ground-spec-relative-permittivity value)
                        (ground-spec-conductivity value))]
          [else
           (raise-argument-error
            'model-ground
            "ground-spec with kind 'none, 'perfect, or 'real"
            value)])]
       [else
        (raise-argument-error
         'model-ground
         "(or/c 'none 'perfect 'real ground-spec?)"
         value)]))))

(define (model-grounded?)
  (not (eq? (ground-spec-kind (model-ground)) 'none)))

(define model-height
  (make-parameter
   0
   (lambda (value)
     (ensure-real 'model-height value "antenna height")
     (when (negative? value)
       (raise-argument-error 'model-height "nonnegative-real?" value))
     value)))
(define maximum-segment-length-override (make-parameter #f))
(define snap-length-override (make-parameter #f))
(define model-frequency (make-parameter 141/10))
;; Compatibility alias for models written before the frequency became a
;; target-independent setting.
(define mmana-frequency model-frequency)

(define (frequency->wavelength frequency-megahertz)
  (ensure-positive-real
   'frequency->wavelength frequency-megahertz "frequency in MHz")
  (/ speed-of-light-metres-per-second
     (* frequency-megahertz hertz-per-megahertz)))

(define (wavelength->frequency wavelength-metres)
  (ensure-positive-real
   'wavelength->frequency wavelength-metres "wavelength in metres")
  (/ speed-of-light-metres-per-second
     (* wavelength-metres hertz-per-megahertz)))

(define (model-wavelength)
  (frequency->wavelength (model-frequency)))

;; Construct a centered paraboloid height field suitable for with-surface.
;; Local X and Y lie in the aperture plane and local Z points toward the dish
;; vertex-to-rim rise.
(define (paraboloid focal-length)
  (ensure-positive-real 'paraboloid focal-length "focal length")
  (lambda (x y)
    (for ([coordinate (in-list (list x y))])
      (ensure-real 'paraboloid coordinate "surface coordinate"))
    (/ (+ (* x x) (* y y)) (* 4 focal-length))))

;; Wrap a flat X/Y parameter sheet around a cylinder whose axis is local Y.
;; X is arc length, while Z is an inward radial offset: at X=0 logical +Z and
;; physical +Z agree. The unoffset surface curves toward local +Z.
(define (cylinder radius)
  (ensure-positive-real 'cylinder radius "radius")
  (lambda (x y z)
    (for ([coordinate (in-list (list x y z))])
      (ensure-real 'cylinder coordinate "warp coordinate"))
    (define angle (/ x radius))
    (define effective-radius (- radius z))
    (list (* effective-radius (sin angle))
          y
          (- radius (* effective-radius (cos angle))))))

(define (hemisphere-height who radius direction)
  (ensure-positive-real who radius "radius")
  (define radius-squared (* radius radius))
  (define tolerance (* 1e-12 radius-squared))
  (lambda (x y)
    (for ([coordinate (in-list (list x y))])
      (ensure-real who coordinate "surface coordinate"))
    (define radicand (- radius-squared (+ (* x x) (* y y))))
    (when (< radicand (- tolerance))
      (error who
             "surface coordinate (~e, ~e) lies outside radius ~e"
             x y radius))
    (define root (sqrt (max 0 radicand)))
    (case direction
      [(dome) (- root radius)]
      [(bowl) (- radius root)])))

;; Both hemisphere helpers place the vertex at local origin. A dome falls from
;; its crown toward -Z; a bowl rises from its bottom toward +Z.
(define (dome radius)
  (hemisphere-height 'dome radius 'dome))

(define (bowl radius)
  (hemisphere-height 'bowl radius 'bowl))

;; Construct a hanging catenary height field suitable for with-surface. The
;; curve runs along local X and is extruded along local Y. Its supports at
;; +/- span/2 have height zero, while its center has height -sag.
(define (catenary span sag)
  (ensure-positive-real 'catenary span "span")
  (ensure-positive-real 'catenary sag "sag")
  (define half-span (/ span 2))
  ;; Solve sag = a * (cosh(half-span/a) - 1). Using the dimensionless
  ;; parameter u = half-span/a makes the monotonic equation well behaved.
  ;; The sinh identity avoids cancellation when the requested sag is shallow.
  (define sag-ratio (exact->inexact (/ sag half-span)))
  (ensure-positive-real 'catenary sag-ratio "sag-to-half-span ratio")
  (define (normalized-sag u)
    (/ (* 2 (sqr (sinh (/ u 2)))) u))
  (define u
    (cond
      ;; For shallow curves, u = 2r + O(r^3). This is more accurate than
      ;; bisecting near zero with fixed-width floating-point endpoints.
      [(< sag-ratio 1e-6) (* 2 sag-ratio)]
      [else
       (define upper
         (let find-upper ([candidate 1.0])
           (if (>= (normalized-sag candidate) sag-ratio)
               candidate
               (find-upper (* 2 candidate)))))
       (let bisect ([lower 0.0] [upper upper] [remaining 100])
         (define midpoint (/ (+ lower upper) 2))
         (cond
           [(or (zero? remaining)
                (= midpoint lower)
                (= midpoint upper))
            midpoint]
           [(< (normalized-sag midpoint) sag-ratio)
            (bisect midpoint upper (sub1 remaining))]
           [else
            (bisect lower midpoint (sub1 remaining))]))]))
  (define parameter-a (/ (exact->inexact half-span) u))
  (ensure-positive-real 'catenary parameter-a "solved catenary parameter")
  (lambda (x y)
    (for ([coordinate (in-list (list x y))])
      (ensure-real 'catenary coordinate "surface coordinate"))
    (define height
      (- (* 2 parameter-a
            (sqr (sinh (/ x (* 2 parameter-a)))))
         sag))
    (ensure-real 'catenary height "surface height")
    height))

(define maximum-segment-length
  (case-lambda
    [()
     (or (maximum-segment-length-override)
         (/ (model-wavelength) 20))]
    [(length)
     (if length
         (begin
           (ensure-positive-real
            'maximum-segment-length length "maximum segment length")
           (maximum-segment-length-override length))
         (maximum-segment-length-override #f))]))

;; Proximity snapping is deliberately much tighter than solver segmentation:
;; it repairs floating-point drift without treating deliberate small gaps as
;; junctions. An explicit zero disables proximity snapping while exact points
;; continue to share one vertex.
(define snap-length
  (case-lambda
    [()
     (if (eq? (snap-length-override) #f)
         (/ (model-wavelength) 1000000)
         (snap-length-override))]
    [(length)
     (cond
       [(eq? length #f) (snap-length-override #f)]
       [else
        (ensure-real 'snap-length length "snap length")
        (when (negative? length)
          (raise-argument-error 'snap-length "nonnegative-real?" length))
        (snap-length-override length)])]))

;; Express a physical length as a count of an arbitrary positive unit. This is
;; especially useful when a geometry is authored in objective millimetres and
;; converted to metres later by with-scale.
(define (span length unit)
  (ensure-real 'span length "length")
  (ensure-positive-real 'span unit "unit")
  (/ length unit))

(define (frequency-retuning-scale observed-frequency-megahertz
                                    target-frequency-megahertz)
  (ensure-positive-real
   'frequency-retuning-scale
   observed-frequency-megahertz
   "observed frequency in MHz")
  (ensure-positive-real
   'frequency-retuning-scale
   target-frequency-megahertz
   "target frequency in MHz")
  (/ observed-frequency-megahertz target-frequency-megahertz))

(define (check-clear-context who)
  (define action
    (if (eq? who 'reset-model!) "reset the model" "clear wires"))
  (when (current-coordinate-warp)
    (error who "cannot ~a inside with-warp or with-surface" action))
  (when (pair? (current-radial-iterations))
    (error who "cannot ~a inside radial-repeat" action)))

(define (clear-construction-state! base-diameter)
  (current-antenna-model (antenna-model '() '()))
  (current-turtle-state (initial-state base-diameter))
  (current-turtle-stack '())
  (pending-feed-location #f)
  (void))

(define (clear-wires)
  (check-clear-context 'clear-wires)
  ;; Wire diameter is a model declaration even though it is carried by the
  ;; turtle state. Preserve its unscaled value while resetting transient
  ;; movement and diameter scales with the rest of the construction state.
  (clear-construction-state!
   (turtle-state-base-diameter (current-turtle-state))))

(define (reset-model!)
  (check-clear-context 'reset-model!)
  (clear-construction-state! millimeter)
  (for ([hook (in-list model-reset-hooks)]) (hook))
  (model-title "Turtle Antenna")
  (model-impedance 50)
  (model-ground 'none)
  (model-height 0)
  (maximum-segment-length-override #f)
  (snap-length-override #f)
  (model-frequency 141/10)
  (void))

(define (validate-model!)
  (when (pending-feed-location)
    (error 'antenna-turtle
           "feed marker was not consumed by a nonzero wire edge"))
  (void))

(define (model-vertices [m (current-antenna-model)])
  (antenna-model-vertices m))

(define (model-edges [m (current-antenna-model)])
  (antenna-model-edges m))

(define (ensure-real who value [description "value"])
  (unless (real? value)
    (raise-argument-error who "real?" value))
  (when (or (nan? value) (infinite? value))
    (error who "~a must be finite; received ~e" description value))
  value)

(define (ensure-positive-real who value [description "value"])
  (ensure-real who value description)
  (unless (> value 0)
    (error who "~a must be positive; received ~e" description value))
  value)

(define (point=? a b)
  (and (= (point3-x a) (point3-x b))
       (= (point3-y a) (point3-y b))
       (= (point3-z a) (point3-z b))))

(define (point+ a b)
  (point3 (+ (point3-x a) (point3-x b))
          (+ (point3-y a) (point3-y b))
          (+ (point3-z a) (point3-z b))))

(define (point- a b)
  (point3 (- (point3-x a) (point3-x b))
          (- (point3-y a) (point3-y b))
          (- (point3-z a) (point3-z b))))

(define (point-scale p factor)
  (point3 (* (point3-x p) factor)
          (* (point3-y p) factor)
          (* (point3-z p) factor)))

(define (point-dot a b)
  (+ (* (point3-x a) (point3-x b))
     (* (point3-y a) (point3-y b))
     (* (point3-z a) (point3-z b))))

(define (point-length-squared p)
  (point-dot p p))

(define (point-length p)
  (sqrt (point-length-squared p)))

(define (mat*point matrix p)
  (define values (list (point3-x p) (point3-y p) (point3-z p)))
  (define (row-dot row)
    (for/sum ([a (in-list row)] [b (in-list values)]) (* a b)))
  (point3 (row-dot (first matrix))
          (row-dot (second matrix))
          (row-dot (third matrix))))

(define (transpose matrix)
  (apply map list matrix))

(define (mat*mat a b)
  (define bt (transpose b))
  (for/list ([row (in-list a)])
    (for/list ([column (in-list bt)])
      (for/sum ([x (in-list row)] [y (in-list column)]) (* x y)))))

;; Return the conventional row-major 3x4 affine transform that places local
;; geometry in the current turtle frame. Nonlinear coordinate warps and radial
;; replication cannot be represented by one affine matrix; solid backends must
;; handle those as explicit future operations rather than silently misplacing
;; geometry.
(define (current-turtle-affine-transform [who 'antenna-turtle])
  (when (current-coordinate-warp)
    (error who "cannot place solid geometry inside with-warp or with-surface"))
  (when (pair? (current-radial-iterations))
    (error who "cannot place solid geometry inside radial-repeat"))
  (define state (current-turtle-state))
  (define position (turtle-state-position state))
  (for/list ([row (in-list (turtle-state-orientation state))]
             [translation (in-list (list (point3-x position)
                                         (point3-y position)
                                         (point3-z position)))])
    (append row (list translation))))

(define (exact-quarter-turn-sin-cos degrees)
  (and (exact? degrees)
       (integer? (/ degrees 90))
       (case (modulo (/ degrees 90) 4)
         [(0) (cons 0 1)]
         [(1) (cons 1 0)]
         [(2) (cons 0 -1)]
         [(3) (cons -1 0)])))

(define (degree-sin-cos degrees)
  (ensure-real 'turn-axis degrees "angle")
  (or (exact-quarter-turn-sin-cos degrees)
      (let ([radians (* degrees (/ pi 180.0))])
        (cons (sin radians) (cos radians)))))

(define (axis-rotation-matrix degrees x y z)
  (for ([component (in-list (list x y z))])
    (ensure-real 'turn-axis component "axis component"))
  (define magnitude (sqrt (+ (* x x) (* y y) (* z z))))
  (when (zero? magnitude)
    (error 'turn-axis "rotation axis must be nonzero"))
  (define ux (/ x magnitude))
  (define uy (/ y magnitude))
  (define uz (/ z magnitude))
  (define sc (degree-sin-cos degrees))
  (define s (car sc))
  (define c (cdr sc))
  (define one-c (- 1 c))
  (list
   (list (+ c (* ux ux one-c))
         (- (* ux uy one-c) (* uz s))
         (+ (* ux uz one-c) (* uy s)))
   (list (+ (* uy ux one-c) (* uz s))
         (+ c (* uy uy one-c))
         (- (* uy uz one-c) (* ux s)))
   (list (- (* uz ux one-c) (* uy s))
         (+ (* uz uy one-c) (* ux s))
         (+ c (* uz uz one-c)))))

(define (turn-axis degrees x y z)
  (define state (current-turtle-state))
  (define local-rotation (axis-rotation-matrix degrees x y z))
  (current-turtle-state
   (struct-copy turtle-state state
     [orientation (mat*mat (turtle-state-orientation state)
                           local-rotation)]))
  (void))

(define (turn-x degrees) (turn-axis degrees 1 0 0))
(define (turn-y degrees) (turn-axis degrees 0 1 0))
(define (turn-z degrees) (turn-axis degrees 0 0 1))

(define (wire-off)
  (current-turtle-state
   (struct-copy turtle-state (current-turtle-state)
     [pen-down? #f]
     [point-anchor #f]))
  (void))

(define (wire-on)
  ;; Explicit movement drawing and stationary point tracing are mutually
  ;; exclusive. Existing point-generated geometry survives; only the open
  ;; trace anchor is discarded.
  (current-turtle-state
   (struct-copy turtle-state (current-turtle-state)
     [pen-down? #t]
     [point-anchor #f]))
  (void))

(define pen-up wire-off)
(define pen-down wire-on)

(define (call-with-wire thunk)
  (unless (and (procedure? thunk) (procedure-arity-includes? thunk 0))
    (raise-argument-error 'call-with-wire "(procedure-arity-includes/c 0)" thunk))
  (when (turtle-state-pen-down? (current-turtle-state))
    (error 'with-wire "wire is already on"))
  (dynamic-wind
    wire-on
    thunk
    wire-off))

(define call-with-pen call-with-wire)

(define (call-with-points thunk)
  (unless (and (procedure? thunk) (procedure-arity-includes? thunk 0))
    (raise-argument-error 'call-with-points
                          "(procedure-arity-includes/c 0)" thunk))
  (define state (current-turtle-state))
  (when (turtle-state-pen-down? state)
    (error 'with-points "wire must be off"))
  (when (turtle-state-point-anchor state)
    (error 'with-points "a point trace is already active"))
  ;; wire-off now doubles as the explicit point-trace terminator. Running it
  ;; in the post-thunk guarantees that a path cannot leak from this lexical
  ;; scope, including when the body exits through an exception.
  (dynamic-wind
    void
    thunk
    wire-off))

(define (call-from-here thunk)
  (unless (and (procedure? thunk) (procedure-arity-includes? thunk 0))
    (raise-argument-error 'call-from-here
                          "(procedure-arity-includes/c 0)"
                          thunk))
  (dynamic-wind push thunk pop))

(define call-with-push call-from-here)

(define (radial-iterations-value)
  (define value (current-radial-iterations))
  (if (pair? value)
      value
      (error 'radial-iterations "used outside radial-repeat")))

(define (call-with-radial-repeat count thunk)
  (unless (exact-positive-integer? count)
    (raise-argument-error 'radial-repeat "exact-positive-integer?" count))
  (validate-thunk 'radial-repeat thunk)
  (when (pending-feed-location)
    (error 'radial-repeat "cannot enter with a pending feed"))
  (define entry-state (current-turtle-state))
  (define entry-stack (current-turtle-stack))
  (define entry-model (current-antenna-model))
  (define outer-iterations (current-radial-iterations))
  (dynamic-wind
    void
    (lambda ()
      (for ([index (in-range count)])
        (define angle (* index (/ 360 count)))
        (define iteration-state
          (struct-copy turtle-state entry-state
            [orientation
             (mat*mat
              (turtle-state-orientation entry-state)
              (axis-rotation-matrix angle 0 0 1))]))
        (parameterize ([current-radial-iterations
                        (append outer-iterations (list (list index count)))]
                       [pending-feed-location #f])
          (dynamic-wind
            (lambda ()
              (current-turtle-state iteration-state)
              (current-turtle-stack entry-stack))
            (lambda ()
              (call-with-values thunk (lambda _ (void)))
              (when (pending-feed-location)
                (error 'radial-repeat
                       "iteration ~a left a feed without a wire edge"
                       index))
              (unless (eq? (current-antenna-model) entry-model)
                (error 'radial-repeat
                       "the body may not replace the current model")))
            (lambda ()
              (current-turtle-state entry-state)
              (current-turtle-stack entry-stack))))))
    (lambda ()
      (current-turtle-state entry-state)
      (current-turtle-stack entry-stack)))
  (void))

(define (validate-thunk who thunk)
  (unless (and (procedure? thunk) (procedure-arity-includes? thunk 0))
    (raise-argument-error who "(procedure-arity-includes/c 0)" thunk)))

(define (validate-mapper who mapper arity)
  (unless (and (procedure? mapper) (procedure-arity-includes? mapper arity))
    (raise-argument-error
     who (format "(procedure-arity-includes/c ~a)" arity) mapper)))

(define (warp-result->point result)
  (unless (and (list? result) (= (length result) 3))
    (raise-arguments-error
     'with-warp
     "coordinate mapper must return a list of exactly three coordinates"
     "result" result))
  (for ([coordinate (in-list result)])
    (ensure-real 'with-warp coordinate "mapped coordinate"))
  (apply point3 result))

(define (map-model-point point)
  (define warp (current-coordinate-warp))
  (cond
    [(not warp) point]
    [else
     (define origin (coordinate-warp-origin warp))
     (define orientation (coordinate-warp-orientation warp))
     (define local
       (mat*point (transpose orientation) (point- point origin)))
     (define mapped-local
       (warp-result->point
        ((coordinate-warp-mapper warp)
         (point3-x local) (point3-y local) (point3-z local))))
     (point+ origin (mat*point orientation mapped-local))]))

(define (call-with-warp mapper thunk)
  (validate-mapper 'with-warp mapper 3)
  (validate-thunk 'with-warp thunk)
  (when (current-coordinate-warp)
    (error 'with-warp "coordinate warps may not be nested"))
  (define entry-state (current-turtle-state))
  (define entry-model (current-antenna-model))
  (define warp
    (coordinate-warp (turtle-state-position entry-state)
                     (turtle-state-orientation entry-state)
                     mapper))
  (parameterize ([current-coordinate-warp warp])
    (call-from-here
     (lambda ()
       (define results (call-with-values thunk list))
       (unless (eq? (current-antenna-model) entry-model)
         (error 'with-warp "the body may not replace the current model"))
       (apply values results)))))

(define (call-with-surface height-function thunk)
  (validate-mapper 'with-surface height-function 2)
  (validate-thunk 'with-surface thunk)
  (call-with-warp
   (lambda (x y z)
     (define height (height-function x y))
     (ensure-real 'with-surface height "surface height")
     (list x y (+ z height)))
   thunk))

(define (scale factor)
  (ensure-positive-real 'scale factor "scale factor")
  (define state (current-turtle-state))
  (current-turtle-state
   (struct-copy turtle-state state
     [movement-scale (* factor (turtle-state-movement-scale state))]))
  (void))

(define (call-with-scale factor thunk)
  (ensure-positive-real 'with-scale factor "scale factor")
  (unless (and (procedure? thunk) (procedure-arity-includes? thunk 0))
    (raise-argument-error 'call-with-scale
                          "(procedure-arity-includes/c 0)"
                          thunk))
  (define initial-movement-scale
    (turtle-state-movement-scale (current-turtle-state)))
  (dynamic-wind
    (lambda () (scale factor))
    thunk
    (lambda ()
      ;; Restore only movement scale. Position, orientation, wire state,
      ;; settings, and other effects produced by the body remain in force.
      (define final-state (current-turtle-state))
      (current-turtle-state
       (struct-copy turtle-state final-state
         [movement-scale initial-movement-scale])))))

(define (scale-all factor)
  (ensure-positive-real 'scale-all factor "scale factor")
  (define state (current-turtle-state))
  (current-turtle-state
   (struct-copy turtle-state state
     [movement-scale (* factor (turtle-state-movement-scale state))]
     [diameter-scale (* factor (turtle-state-diameter-scale state))]))
  (void))

(define (wire-diameter diameter)
  (ensure-positive-real 'wire-diameter diameter "wire diameter")
  (current-turtle-state
   (struct-copy turtle-state (current-turtle-state)
     [base-diameter diameter]))
  (void))

(define (current-wire-diameter)
  (define state (current-turtle-state))
  (* (turtle-state-base-diameter state)
     (turtle-state-diameter-scale state)))

(define (current-position)
  (turtle-state-position (current-turtle-state)))

(define (here)
  (current-position))

(define (push)
  (current-turtle-stack
   (cons (current-turtle-state) (current-turtle-stack)))
  (void))

(define (pop)
  (when (null? (current-turtle-stack))
    (error 'pop "turtle stack is empty"))
  (current-turtle-state (car (current-turtle-stack)))
  (current-turtle-stack (cdr (current-turtle-stack)))
  (void))

(define feed-locations '(start center end))

(define (make-feed-spec location [name #f] [amplitude 1.0] [phase 0.0])
  (unless (memq location feed-locations)
    (raise-argument-error
     'make-feed-spec "(or/c 'start 'center 'end)" location))
  (unless (or (not name) (and (string? name) (not (string=? name ""))))
    (raise-argument-error
     'make-feed-spec "(or/c #f non-empty-string?)" name))
  (ensure-real 'make-feed-spec amplitude "feed amplitude")
  (unless (>= amplitude 0)
    (raise-argument-error
     'make-feed-spec "nonnegative-real?" amplitude))
  (ensure-real 'make-feed-spec phase "feed phase")
  (feed-spec location name amplitude phase))

(define (normalize-feed-info value)
  (cond
    [(feed-spec? value)
     (make-feed-spec (feed-spec-location value)
                     (feed-spec-name value)
                     (feed-spec-amplitude value)
                     (feed-spec-phase value))]
    [(memq value feed-locations) (make-feed-spec value)]
    [else
     (raise-argument-error
      'feed
      "(or/c 'start 'center 'end feed-spec?)"
      value)]))

(define (mark-feed descriptor)
  (when (pending-feed-location)
    (error 'feed "a feed marker is already waiting for a drawn edge"))
  (pending-feed-location (normalize-feed-info descriptor))
  (void))

;; Retain the pre-0.5 procedure binding for old compiled modules and programs
;; that require the private core directly. The public language shadows it with
;; the contextual feed macro.
(define feed mark-feed)

(define (wire-edge-feed? edge)
  (and (wire-edge-feed-info edge) #t))

(define (wire-edge-feed-location edge)
  (define info (wire-edge-feed-info edge))
  (cond [(feed-spec? info) (feed-spec-location info)]
        [(memq info feed-locations) info]
        [else #f]))

(define (wire-edge-feed-name edge)
  (define info (wire-edge-feed-info edge))
  (and (feed-spec? info) (feed-spec-name info)))

(define (wire-edge-feed-amplitude edge)
  (define info (wire-edge-feed-info edge))
  (cond [(feed-spec? info) (feed-spec-amplitude info)]
        [(memq info feed-locations) 1.0]
        [else #f]))

(define (wire-edge-feed-phase edge)
  (define info (wire-edge-feed-info edge))
  (cond [(feed-spec? info) (feed-spec-phase info)]
        [(memq info feed-locations) 0.0]
        [else #f]))

(define (used-feed-names [edges (model-edges)])
  (filter values (map wire-edge-feed-name edges)))

(define (fresh-feed-name used)
  (let loop ([index 1])
    (define candidate (format "feed-~a" index))
    (if (member candidate used) (loop (add1 index)) candidate)))

(define (finalize-feed-info info)
  (and info
       (let* ([normalized (normalize-feed-info info)]
              [used (used-feed-names)]
              [requested (feed-spec-name normalized)]
              [name (or requested (fresh-feed-name used))])
         (when (member name used)
           (raise-arguments-error
            'feed "feed names must be unique" "name" name))
         (struct-copy feed-spec normalized [name name]))))

(define (find-equal-vertex point)
  (for/first ([candidate (in-list (model-vertices))]
              #:when (point=? point (vertex-point candidate)))
    candidate))

(define (find-snap-vertex point [excluded #f])
  (define tolerance (snap-length))
  (and (positive? tolerance)
       (for/fold ([best #f]
                  [best-distance #f]
                  #:result best)
                 ([candidate (in-list (model-vertices))]
                  #:unless (eq? candidate excluded))
         (define distance
           (squared-distance point (vertex-point candidate)))
         (if (and (<= distance (* tolerance tolerance))
                  (or (not best-distance) (< distance best-distance)))
             (values candidate distance)
             (values best best-distance)))))

(define (intern-vertex! point [excluded #f])
  (or (let ([equal (find-equal-vertex point)])
        (and (not (eq? equal excluded)) equal))
      (find-snap-vertex point excluded)
      (let* ([m (current-antenna-model)]
             [vertices (antenna-model-vertices m)]
             [new-vertex (vertex (add1 (length vertices)) point)])
        (set-antenna-model-vertices! m (append vertices (list new-vertex)))
        new-vertex)))

(define (append-edge! start-point end-point)
  (define finalized-feed (finalize-feed-info (pending-feed-location)))
  (define physical-start-point (map-model-point start-point))
  (define physical-end-point (map-model-point end-point))
  (when (and (current-coordinate-warp)
             (not (point=? start-point end-point))
             (point=? physical-start-point physical-end-point))
    (error 'with-warp
           "coordinate mapper collapsed a nonzero wire edge to one point"))
  (define m (current-antenna-model))
  (define edges (antenna-model-edges m))
  (define start (intern-vertex! physical-start-point))
  ;; Do not collapse an intentionally short new edge merely because its end is
  ;; within the snapping tolerance of its own source. Exact closure to that
  ;; source remains a zero-length movement, as it was before snapping existed.
  (define end
    (if (point=? physical-end-point (vertex-point start))
        start
        (intern-vertex! physical-end-point start)))
  (cond
    [(eq? start end)
     (when (pending-feed-location)
       (error 'feed "cannot place a feed on a zero-length edge"))]
    [else
     (define new-edge
       (wire-edge (add1 (length edges))
                  start
                  end
                  (current-wire-diameter)
                  finalized-feed))
     (set-antenna-model-edges! m (append edges (list new-edge)))
     (when (pending-feed-location) (pending-feed-location #f))])
  (values (vertex-point start) (vertex-point end)))

(define (same-undirected-edge? edge start end diameter)
  (and (= (wire-edge-diameter edge) diameter)
       (or (and (eq? (wire-edge-start edge) start)
                (eq? (wire-edge-end edge) end))
           (and (eq? (wire-edge-start edge) end)
                (eq? (wire-edge-end edge) start)))))

(define (append-reflected-edge! start-point end-point diameter)
  (define m (current-antenna-model))
  (define start (intern-vertex! start-point))
  (define end
    (if (point=? end-point (vertex-point start))
        start
        (intern-vertex! end-point start)))
  (unless (or (eq? start end)
              (for/or ([edge (in-list (antenna-model-edges m))])
                (same-undirected-edge? edge start end diameter)))
    (define edges (antenna-model-edges m))
    (define reflected-edge
      (wire-edge (add1 (length edges)) start end diameter #f))
    (set-antenna-model-edges! m (append edges (list reflected-edge))))
  (void))

(define (reflect-point-across-plane point anchor normal)
  (define offset (point- point anchor))
  (define normal-length-squared (point-length-squared normal))
  (define projection-factor
    (/ (* 2 (point-dot offset normal)) normal-length-squared))
  (point- point (point-scale normal projection-factor)))

(define (call-with-reflection axis thunk)
  (when (current-coordinate-warp)
    (error 'reflect "reflect may not be used inside with-warp or with-surface"))
  (unless (memq axis '(x y z))
    (raise-argument-error 'call-with-reflection "(or/c 'x 'y 'z)" axis))
  (unless (and (procedure? thunk) (procedure-arity-includes? thunk 0))
    (raise-argument-error 'call-with-reflection
                          "(procedure-arity-includes/c 0)"
                          thunk))
  (define entry-model (current-antenna-model))
  (define entry-edge-count (length (model-edges entry-model)))
  (define entry-state (current-turtle-state))
  (define anchor (turtle-state-position entry-state))
  (define local-normal
    (case axis
      [(x) (point3 1 0 0)]
      [(y) (point3 0 1 0)]
      [(z) (point3 0 0 1)]))
  (define normal
    (mat*point (turtle-state-orientation entry-state) local-normal))
  ;; Execute arbitrary user code once. Reflection copies only the geometry it
  ;; produced, so feeds and unrelated Racket side effects are never repeated.
  (define results (call-with-values thunk list))
  (unless (eq? (current-antenna-model) entry-model)
    (error 'reflect "the body may not reset or replace the current model"))
  (define current-edges (model-edges entry-model))
  (when (< (length current-edges) entry-edge-count)
    (error 'reflect "the body may not remove existing model edges"))
  (define created-edges (drop current-edges entry-edge-count))
  (for ([edge (in-list created-edges)])
    (append-reflected-edge!
     (reflect-point-across-plane
      (vertex-point (wire-edge-start edge)) anchor normal)
     (reflect-point-across-plane
      (vertex-point (wire-edge-end edge)) anchor normal)
     (wire-edge-diameter edge)))
  (apply values results))

(define (perform-movement destination)
  (define state (current-turtle-state))
  (define source (turtle-state-position state))
  (define draws? (turtle-state-pen-down? state))
  (when (and (pending-feed-location) (not draws?))
    (error 'feed "the movement following feed occurred while the wire was off"))
  (when (and (pending-feed-location) (point=? source destination))
    (error 'feed "the movement following feed must create a nonzero edge"))
  (define-values (canonical-source canonical-destination)
    (if (and draws? (not (point=? source destination)))
        (append-edge! source destination)
        (values source destination)))
  (current-turtle-state
   (struct-copy turtle-state state
     [position (if (current-coordinate-warp)
                   destination
                   canonical-destination)]
     [previous-source (if (current-coordinate-warp)
                          source
                          canonical-source)]))
  (void))

(define (goto destination)
  (unless (point3? destination)
    (raise-argument-error 'goto "point3?" destination))
  (for ([component (in-list (list (point3-x destination)
                                  (point3-y destination)
                                  (point3-z destination)))])
    (ensure-real 'goto component "coordinate"))
  (perform-movement destination))

(define (move-vector-local x-distance y-distance z-distance)
  (for ([component (in-list (list x-distance y-distance z-distance))])
    (ensure-real 'move component "distance component"))
  (define state (current-turtle-state))
  (define movement-scale (turtle-state-movement-scale state))
  (define displacement
    (mat*point (turtle-state-orientation state)
               (point3 (* x-distance movement-scale)
                       (* y-distance movement-scale)
                       (* z-distance movement-scale))))
  (perform-movement (point+ (turtle-state-position state) displacement)))

(define (move-vector-local-steps x-distance y-distance z-distance step-count)
  (for ([component (in-list (list x-distance y-distance z-distance))])
    (ensure-real 'move component "distance component"))
  (unless (exact-positive-integer? step-count)
    (raise-argument-error 'move "exact-positive-integer?" step-count))
  (when (pending-feed-location)
    (error 'move
           "a segmented move cannot consume a pending feed; mark one segment explicitly"))
  (define state (current-turtle-state))
  (define origin (turtle-state-position state))
  (define movement-scale (turtle-state-movement-scale state))
  (define displacement
    (mat*point (turtle-state-orientation state)
               (point3 (* x-distance movement-scale)
                       (* y-distance movement-scale)
                       (* z-distance movement-scale))))
  ;; Calculate every target from the original point rather than accumulating
  ;; increments. This reaches the intended endpoint exactly when the input
  ;; arithmetic is exact and minimizes floating-point drift otherwise.
  (for ([index (in-range 1 (add1 step-count))])
    (perform-movement
     (point+ origin (point-scale displacement (/ index step-count)))))
  (void))

;; Emit a stationary point-trace endpoint relative to the current turtle
;; frame. Unlike movement, this does not change the turtle position. The first
;; point merely establishes an anchor; each later point emits one edge and
;; advances that anchor to the canonical (possibly snapped) endpoint.
(define (point-vector-local x-distance y-distance z-distance
                            [inline-feed-location #f])
  (for ([component (in-list (list x-distance y-distance z-distance))])
    (ensure-real 'point component "distance component"))
  (when inline-feed-location (normalize-feed-info inline-feed-location))
  (define state (current-turtle-state))
  (when (turtle-state-pen-down? state)
    (error 'point "point tracing requires the wire to be off"))
  (define anchor (turtle-state-point-anchor state))
  (when (and (not anchor)
             (or inline-feed-location (pending-feed-location)))
    (error 'point "cannot place a feed on the first point of a trace"))
  (define movement-scale (turtle-state-movement-scale state))
  (define displacement
    (mat*point (turtle-state-orientation state)
               (point3 (* x-distance movement-scale)
                       (* y-distance movement-scale)
                       (* z-distance movement-scale))))
  (define destination
    (point+ (turtle-state-position state) displacement))
  (cond
    [(not anchor)
     ;; Do not intern an isolated point. If the trace is abandoned, it leaves
     ;; no invisible model vertex for snapping or move-nearest to discover.
     (current-turtle-state
      (struct-copy turtle-state state [point-anchor destination]))]
    [else
     (when inline-feed-location (mark-feed inline-feed-location))
     (define-values (_canonical-source canonical-destination)
       (append-edge! anchor destination))
     (current-turtle-state
      (struct-copy turtle-state state
        [point-anchor (if (current-coordinate-warp)
                          destination
                          canonical-destination)]))])
  (void))

(define (move-local x y z distance)
  (for ([component (in-list (list x y z))])
    (ensure-real 'move-local component "direction component"))
  (ensure-real 'move-local distance "distance")
  (move-vector-local (* x distance) (* y distance) (* z distance)))

(define (spread-local x y z distance)
  (for ([component (in-list (list x y z))])
    (ensure-real 'spread component "direction component"))
  (ensure-real 'spread distance "distance")
  (define center-state (current-turtle-state))
  (define scaled-distance
    (* distance (turtle-state-movement-scale center-state)))
  (define half-displacement
    (mat*point (turtle-state-orientation center-state)
               (point3 (* x (/ scaled-distance 2))
                       (* y (/ scaled-distance 2))
                       (* z (/ scaled-distance 2)))))
  ;; Reposition silently to the endpoint opposite the requested direction.
  ;; In particular, do not consume a pending feed: the single full-length
  ;; movement below is the segment whose midpoint is the original center.
  (define start (point- (turtle-state-position center-state)
                        half-displacement))
  (dynamic-wind
    (lambda ()
      (current-turtle-state
       (struct-copy turtle-state center-state [position start])))
    (lambda ()
      (perform-movement
       (point+ start (point-scale half-displacement 2))))
    (lambda ()
      ;; Spread lays geometry around the turtle; it is not turtle movement.
      ;; Restore the complete state so position, orientation, point tracing,
      ;; scale, diameter, and movement history are unchanged even if drawing
      ;; the centered edge raises an exception.
      (current-turtle-state center-state))))

(define (forward distance)
  (move-local 1 0 0 distance))

(define forwards forward)

(define (back distance)
  (move-local -1 0 0 distance))

(define backward back)
(define backwards back)

(define (squared-distance a b)
  (point-length-squared (point- a b)))

(define (move-nearest)
  (when (current-coordinate-warp)
    (error 'move-nearest
           "move-nearest is unavailable inside with-warp or with-surface"))
  (define state (current-turtle-state))
  (define here (turtle-state-position state))
  (define previous (turtle-state-previous-source state))
  (define candidates
    (filter (lambda (candidate)
              (define p (vertex-point candidate))
              (and (not (point=? p here))
                   (or (not previous) (not (point=? p previous)))))
            (model-vertices)))
  (when (null? candidates)
    (error 'move-nearest "no eligible model vertex exists"))
  ;; sort is stable, so equal distances retain creation order.
  (define closest
    (first
     (sort candidates <
           #:key (lambda (candidate)
                   (squared-distance here (vertex-point candidate))))))
  (perform-movement (vertex-point closest)))

(define (edge-length edge)
  (point-length
   (point- (vertex-point (wire-edge-end edge))
           (vertex-point (wire-edge-start edge)))))

;; Return the physical conductor length represented by the model. Computing
;; this from the finished edges keeps the measurement honest after scaling,
;; point tracing, snapping, reflection, or any future geometry transform.
;; Exporter subdivision does not change physical wire length and is therefore
;; intentionally irrelevant here.
(define (wire-used [m (current-antenna-model)])
  (for/sum ([edge (in-list (model-edges m))])
    (edge-length edge)))

(define (edge-segment-count
         edge
         [max-length (maximum-segment-length)])
  (ensure-positive-real 'edge-segment-count max-length
                        "maximum segment length")
  (define base-count
    (max 1 (inexact->exact (ceiling (/ (edge-length edge) max-length)))))
  (if (and (eq? (wire-edge-feed-location edge) 'center)
           (even? base-count))
      (add1 base-count)
      base-count))

(define (half x)
  (/ x 2))
