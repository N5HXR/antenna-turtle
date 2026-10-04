#lang racket/base

(require racket/list
         racket/math)

(provide
 ;; Exact length constants, in meters.
 meter meters centimeter centimeters millimeter millimeters
 inch inches foot feet

 ;; Antenna arithmetic.
 frequency->wavelength wavelength->frequency model-wavelength
 span frequency-retuning-scale

 ;; Model data, useful to tooling and tests.
 (struct-out point3)
 (struct-out vertex)
 (struct-out wire-edge)
 (struct-out antenna-model)
 current-antenna-model
 model-vertices
 model-edges

 ;; Model settings.
 reset-model!
 validate-model!
 model-title
 maximum-segment-length
 model-frequency
 mmana-frequency

 ;; Turtle operations.
 pen-up pen-down call-with-pen call-with-scale call-with-push
 forward back move-local move-vector-local spread-local move-nearest
 turn-x turn-y turn-z turn-axis
 scale scale-all
 wire-diameter
 push pop
 feed

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
(struct wire-edge (id start end diameter feed?) #:transparent)
(struct antenna-model (vertices edges) #:mutable #:transparent)

;; An orientation is a row-major 3x3 local-to-global matrix.
(struct turtle-state
  (position orientation pen-down? movement-scale diameter-scale
            base-diameter previous-source)
  #:transparent)

(define identity-matrix
  '((1 0 0)
    (0 1 0)
    (0 0 1)))

(define (initial-state)
  (turtle-state (point3 0 0 0)
                identity-matrix
                #f
                1
                1
                millimeter
                #f))

(define current-antenna-model
  (make-parameter (antenna-model '() '())))
(define current-turtle-state (make-parameter (initial-state)))
(define current-turtle-stack (make-parameter '()))
(define pending-feed? (make-parameter #f))

;; These are ordinary Racket parameters: callers can dynamically scope them,
;; or set them for the remainder of a module with a one-argument call.
(define model-title (make-parameter "Antenna Turtle model"))
(define maximum-segment-length (make-parameter #f))
(define model-frequency (make-parameter 1.0))
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

(define (reset-model!)
  (current-antenna-model (antenna-model '() '()))
  (current-turtle-state (initial-state))
  (current-turtle-stack '())
  (pending-feed? #f)
  (model-title "Antenna Turtle model")
  (maximum-segment-length #f)
  (model-frequency 1.0)
  (void))

(define (validate-model!)
  (when (pending-feed?)
    (error 'antenna-turtle "feed marker was not consumed by a nonzero pen-down movement"))
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

(define (pen-up)
  (current-turtle-state
   (struct-copy turtle-state (current-turtle-state) [pen-down? #f]))
  (void))

(define (pen-down)
  (current-turtle-state
   (struct-copy turtle-state (current-turtle-state) [pen-down? #t]))
  (void))

(define (call-with-pen thunk)
  (unless (and (procedure? thunk) (procedure-arity-includes? thunk 0))
    (raise-argument-error 'call-with-pen "(procedure-arity-includes/c 0)" thunk))
  (when (turtle-state-pen-down? (current-turtle-state))
    (error 'with-pen "pen is already down"))
  (dynamic-wind
    pen-down
    thunk
    pen-up))

(define (call-with-push thunk)
  (unless (and (procedure? thunk) (procedure-arity-includes? thunk 0))
    (raise-argument-error 'call-with-push
                          "(procedure-arity-includes/c 0)"
                          thunk))
  (dynamic-wind push thunk pop))

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
      ;; Restore only movement scale. Position, orientation, pen state, wire
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

(define (feed)
  (when (pending-feed?)
    (error 'feed "a feed marker is already waiting for a drawn edge"))
  (pending-feed? #t)
  (void))

(define (find-equal-vertex point)
  (for/first ([candidate (in-list (model-vertices))]
              #:when (point=? point (vertex-point candidate)))
    candidate))

(define (intern-vertex! point)
  (or (find-equal-vertex point)
      (let* ([m (current-antenna-model)]
             [vertices (antenna-model-vertices m)]
             [new-vertex (vertex (add1 (length vertices)) point)])
        (set-antenna-model-vertices! m (append vertices (list new-vertex)))
        new-vertex)))

(define (append-edge! start-point end-point)
  (define m (current-antenna-model))
  (define edges (antenna-model-edges m))
  (define start (intern-vertex! start-point))
  (define end (intern-vertex! end-point))
  (cond
    [(eq? start end)
     (when (pending-feed?)
       (error 'feed "cannot place a feed on a zero-length edge"))]
    [else
     (define new-edge
       (wire-edge (add1 (length edges))
                  start
                  end
                  (current-wire-diameter)
                  (pending-feed?)))
     (set-antenna-model-edges! m (append edges (list new-edge)))
     (when (pending-feed?) (pending-feed? #f))])
  (void))

(define (perform-movement destination)
  (define state (current-turtle-state))
  (define source (turtle-state-position state))
  (define draws? (turtle-state-pen-down? state))
  (when (and (pending-feed?) (not draws?))
    (error 'feed "the movement following feed occurred while the pen was up"))
  (when (and (pending-feed?) (point=? source destination))
    (error 'feed "the movement following feed must create a nonzero edge"))
  (when (and draws? (not (point=? source destination)))
    (append-edge! source destination))
  (current-turtle-state
   (struct-copy turtle-state state
     [position destination]
     [previous-source source]))
  (void))

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
  (current-turtle-state
   (struct-copy turtle-state center-state [position start]))
  (perform-movement (point+ start (point-scale half-displacement 2))))

(define (forward distance)
  (move-local 1 0 0 distance))

(define (back distance)
  (move-local -1 0 0 distance))

(define (squared-distance a b)
  (point-length-squared (point- a b)))

(define (move-nearest)
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

(define (edge-segment-count edge [max-length (maximum-segment-length)])
  (ensure-positive-real 'edge-segment-count max-length
                        "maximum segment length")
  (define base-count
    (max 1 (inexact->exact (ceiling (/ (edge-length edge) max-length)))))
  (if (and (wire-edge-feed? edge) (even? base-count))
      (add1 base-count)
      base-count))
