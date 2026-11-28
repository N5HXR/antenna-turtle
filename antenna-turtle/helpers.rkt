#lang racket/base

;; Common antenna-construction geometry that should not need to be reinvented
;; in each model.  Keep this module independent of the surface DSL: helpers
;; emit ordinary local wire geometry, so callers may freely wrap them in
;; with-surface or with-warp.

(require racket/list
         racket/math
         (for-syntax racket/base racket/list)
         (only-in "private/core.rkt"
                  call-from-here
                  call-with-points
                  call-with-radial-repeat
                  point-vector-local
                  set-wire-diameter-for-geometry!
                  turn-z
                  wire-off))

(provide rectangular-wire-mesh
         cuboid-wire-mesh
         circular-wire-mesh
         circular-shielded-reflector)

(begin-for-syntax
  (define (mesh-settings stx items)
    (define values (syntax->list items))
    (when (odd? (length values))
      (raise-syntax-error
       'cuboid-wire-mesh
       "expected size, divisions, and optional anchor setting/value pairs"
       stx))
    (define result (make-hasheq))
    (for ([offset (in-range 0 (length values) 2)])
      (define key-stx (list-ref values offset))
      (unless (identifier? key-stx)
        (raise-syntax-error
         'cuboid-wire-mesh "expected a contextual setting name" stx key-stx))
      (define key (syntax-e key-stx))
      (unless (memq key '(size divisions anchor))
        (raise-syntax-error
         'cuboid-wire-mesh
         "expected size, divisions, or anchor"
         stx key-stx))
      (when (hash-has-key? result key)
        (raise-syntax-error
         'cuboid-wire-mesh "setting may be specified only once" stx key-stx))
      (hash-set! result key (list-ref values (add1 offset))))
    result)

  (define (mesh-anchor-expression value)
    (cond
      [(not value) #''center]
      [(identifier? value) #`'#,(syntax-e value)]
      [else value])))

(define (positive-finite-real? value)
  (and (real? value)
       (not (nan? value))
       (not (infinite? value))
       (positive? value)))

(define (finite-real? value)
  (and (real? value)
       (not (nan? value))
       (not (infinite? value))))

(define (rectangular-wire-mesh length width length-divisions width-divisions)
  "Draw a centered, electrically connected rectangular wire mesh.

LENGTH runs along the turtle's local forward axis and WIDTH along its local
left axis. The division counts specify cells, not wires, so every crossing is
emitted as a shared model vertex. The helper owns its point traces and restores
the complete caller turtle state."
  (unless (positive-finite-real? length)
    (raise-argument-error
     'rectangular-wire-mesh "positive finite real?" length))
  (unless (positive-finite-real? width)
    (raise-argument-error
     'rectangular-wire-mesh "positive finite real?" width))
  (unless (exact-positive-integer? length-divisions)
    (raise-argument-error
     'rectangular-wire-mesh "exact-positive-integer?" length-divisions))
  (unless (exact-positive-integer? width-divisions)
    (raise-argument-error
     'rectangular-wire-mesh "exact-positive-integer?" width-divisions))
  ;; Point traces let this constructor own its conductor state, like the
  ;; circular mesh helper, without relocating or otherwise disturbing the
  ;; turtle that invoked it.
  (call-from-here
   (lambda ()
     (wire-off)
     ;; Parallel forward wires, each subdivided at every column crossing.
     (for ([row (in-range (add1 width-divisions))])
       (define y (- (* width (/ row width-divisions)) (/ width 2)))
       (call-with-points
        (lambda ()
          (for ([column (in-range (add1 length-divisions))])
            (point-vector-local
             (- (* length (/ column length-divisions)) (/ length 2)) y 0)))))
     ;; Parallel left wires, each subdivided at every row crossing.
     (for ([column (in-range (add1 length-divisions))])
       (define x (- (* length (/ column length-divisions)) (/ length 2)))
       (call-with-points
        (lambda ()
          (for ([row (in-range (add1 width-divisions))])
            (point-vector-local
             x (- (* width (/ row width-divisions)) (/ width 2)) 0)))))))
  (void))

(define cuboid-anchor-axis
  (hash 'front   (cons 0 'maximum)
        'forward (cons 0 'maximum)
        'back    (cons 0 'minimum)
        'left    (cons 1 'maximum)
        'right   (cons 1 'minimum)
        'top     (cons 2 'maximum)
        'up      (cons 2 'maximum)
        'bottom  (cons 2 'minimum)
        'down    (cons 2 'minimum)))

(define (three-values who description value predicate)
  (define result
    (cond
      [(and (list? value) (= (length value) 3)) value]
      [(and (vector? value) (= (vector-length value) 3))
       (vector->list value)]
      [else #f]))
  (unless (and result (andmap predicate result))
    (raise-argument-error who description value))
  result)

(define (cuboid-anchor-point size anchor)
  (define minimum (map (lambda (dimension) (- (/ dimension 2))) size))
  (define maximum (map (lambda (dimension) (/ dimension 2)) size))
  (cond
    [(memq anchor '(center origin)) '(0 0 0)]
    [(or (and (list? anchor) (= (length anchor) 3)
              (andmap finite-real? anchor))
         (and (vector? anchor) (= (vector-length anchor) 3)
              (andmap finite-real? (vector->list anchor))))
     (if (vector? anchor) (vector->list anchor) anchor)]
    [else
     (define directions (if (symbol? anchor) (list anchor) anchor))
     (unless (and (list? directions) (pair? directions)
                  (andmap symbol? directions))
       (raise-argument-error
        'cuboid-wire-mesh
        "anchor direction, list of orthogonal directions, or local point"
        anchor))
     (define selected (make-hasheq))
     (for ([direction (in-list directions)])
       (define selection (hash-ref cuboid-anchor-axis direction #f))
       (unless selection
         (raise-arguments-error
          'cuboid-wire-mesh "unknown anchor direction" "direction" direction))
       (define axis (car selection))
       (when (hash-has-key? selected axis)
         (raise-arguments-error
          'cuboid-wire-mesh
          "anchor directions must select at most one face per axis"
          "anchor" anchor))
       (hash-set! selected axis (cdr selection)))
     (for/list ([axis (in-range 3)])
       (case (hash-ref selected axis 'center)
         [(minimum) (list-ref minimum axis)]
         [(maximum) (list-ref maximum axis)]
         [else 0]))]))

(define (near-integer? value)
  (< (abs (- value (round value))) 1e-9))

(define (draw-cuboid-wire-mesh size divisions anchor)
  (define dimensions
    (three-values
     'cuboid-wire-mesh
     "three-element list or vector of positive finite reals"
     size
     positive-finite-real?))
  (define counts
    (three-values
     'cuboid-wire-mesh
     "three-element list or vector of exact positive integers"
     divisions
     exact-positive-integer?))
  (define anchor-point (cuboid-anchor-point dimensions anchor))
  (define centered-minimum
    (map (lambda (dimension) (- (/ dimension 2))) dimensions))
  (define spacings (map / dimensions counts))

  ;; The anchor is useful as a feed or attachment point only when it is an
  ;; authored grid junction. Directional center coordinates therefore imply
  ;; even division counts, while face and corner coordinates need no special
  ;; parity rule. This general test also handles explicit local-point anchors.
  (for ([coordinate (in-list anchor-point)]
        [minimum (in-list centered-minimum)]
        [spacing (in-list spacings)]
        [count (in-list counts)])
    (define grid-index (/ (- coordinate minimum) spacing))
    (unless (and (<= 0 grid-index count) (near-integer? grid-index))
      (raise-arguments-error
       'cuboid-wire-mesh
       "anchor must coincide with a wire-grid junction; use even division counts on centered axes"
       "anchor" anchor
       "size" size
       "divisions" divisions)))

  (define minimum (map - centered-minimum anchor-point))
  (define length (first dimensions))
  (define width (second dimensions))
  (define height (third dimensions))
  (define nx (first counts))
  (define ny (second counts))
  (define nz (third counts))

  ;; A square grid with pitch p has equal-area diameter p/pi: each of its two
  ;; wire families accounts for one copy of the represented sheet area. For a
  ;; finite cuboid, compute the same rule globally using every unique lattice
  ;; edge. This preserves one diameter at all junctions even when the three
  ;; resolved pitches differ.
  (define surface-area
    (* 2 (+ (* length width) (* length height) (* width height))))
  (define total-wire-length
    (+ (* length (+ (* 2 ny) (* 2 nz)))
       (* width (+ (* 2 nx) (* 2 nz)))
       (* height (+ (* 2 nx) (* 2 ny)))))
  (define equal-area-diameter
    (/ (* 2 surface-area) (* pi total-wire-length)))

  (define (coordinate axis index)
    (+ (list-ref minimum axis)
       (* index (list-ref spacings axis))))
  (define (boundary? index count)
    (or (zero? index) (= index count)))
  (define (trace-points points)
    (call-with-points
     (lambda ()
       (for ([point (in-list points)])
         (apply point-vector-local point)))))

  (call-from-here
   (lambda ()
     (wire-off)
     (set-wire-diameter-for-geometry! equal-area-diameter)

     ;; X-directed surface lines. The boundary predicate emits each cuboid
     ;; edge only once rather than once for each adjacent face.
     (for* ([iy (in-range (add1 ny))]
            [iz (in-range (add1 nz))]
            #:when (or (boundary? iy ny) (boundary? iz nz)))
       (trace-points
        (for/list ([ix (in-range (add1 nx))])
          (list (coordinate 0 ix) (coordinate 1 iy) (coordinate 2 iz)))))

     ;; Y-directed surface lines.
     (for* ([ix (in-range (add1 nx))]
            [iz (in-range (add1 nz))]
            #:when (or (boundary? ix nx) (boundary? iz nz)))
       (trace-points
        (for/list ([iy (in-range (add1 ny))])
          (list (coordinate 0 ix) (coordinate 1 iy) (coordinate 2 iz)))))

     ;; Z-directed surface lines.
     (for* ([ix (in-range (add1 nx))]
            [iy (in-range (add1 ny))]
            #:when (or (boundary? ix nx) (boundary? iy ny)))
       (trace-points
        (for/list ([iz (in-range (add1 nz))])
          (list (coordinate 0 ix) (coordinate 1 iy) (coordinate 2 iz)))))))
  (void))

(define-syntax (cuboid-wire-mesh stx)
  (syntax-case stx ()
    [(_ setting ...)
     (let* ([values (mesh-settings stx #'(setting ...))]
            [size (hash-ref values 'size #f)]
            [divisions (hash-ref values 'divisions #f)])
       (unless size
         (raise-syntax-error 'cuboid-wire-mesh "size is required" stx))
       (unless divisions
         (raise-syntax-error 'cuboid-wire-mesh "divisions is required" stx))
       #`(draw-cuboid-wire-mesh
          #,size
          #,divisions
          #,(mesh-anchor-expression (hash-ref values 'anchor #f))))]))

(define (draw-circular-wire-mesh outer-diameter inner-diameter
                                 ribcount ringcount annular?)
  (unless (positive-finite-real? outer-diameter)
    (raise-argument-error
     'circular-wire-mesh "positive finite real?" outer-diameter))
  (when annular?
    (unless (and (positive-finite-real? inner-diameter)
                 (< inner-diameter outer-diameter))
      (raise-argument-error
       'circular-wire-mesh
       "positive finite real? less than outer-diameter"
       inner-diameter)))
  (unless (and (exact-integer? ribcount) (>= ribcount 3))
    (raise-argument-error
     'circular-wire-mesh "exact-integer? greater than or equal to 3" ribcount))
  (unless (exact-positive-integer? ringcount)
    (raise-argument-error
     'circular-wire-mesh "exact-positive-integer?" ringcount))
  (when (and annular? (< ringcount 2))
    (raise-argument-error
     'circular-wire-mesh
     "exact-integer? greater than or equal to 2 for an annular mesh"
     ringcount))

  (define outer-radius (/ outer-diameter 2))
  (define inner-radius (and annular? (/ inner-diameter 2)))
  (define azimuth-step (/ 360 ribcount))
  (define ring-radii
    (if annular?
        (for/list ([ring-index (in-range ringcount)])
          (+ inner-radius
             (* ring-index
                (/ (- outer-radius inner-radius) (sub1 ringcount)))))
        (for/list ([ring-index (in-range 1 (add1 ringcount))])
          (* ring-index (/ outer-radius ringcount)))))

  ;; Point traces let this constructor own its wire state without moving the
  ;; logical turtle.  The enclosing from-here semantics also make it safe to
  ;; call from within a larger with-wire construction: the caller's open trace
  ;; is restored after this self-contained mesh has been emitted.
  (call-from-here
   (lambda ()
     (wire-off)

     ;; Segment every rib at its ring crossings.  Besides improving curved
     ;; surface approximation, this gives ring endpoints exact places to snap.
     (call-with-radial-repeat
      ribcount
      (lambda ()
        (call-with-points
         (lambda ()
           (unless annular?
             (point-vector-local 0 0 0))
           (for ([ring-radius (in-list ring-radii)])
             (point-vector-local ring-radius 0 0))))))

     ;; Each repeated chord joins adjacent ribs.  The final chord closes onto
     ;; the first through the model's ordinary vertex snapping behavior.
     (for ([ring-radius (in-list ring-radii)])
       (call-with-radial-repeat
        ribcount
        (lambda ()
          (call-with-points
           (lambda ()
             (point-vector-local ring-radius 0 0)
             (turn-z azimuth-step)
             (point-vector-local ring-radius 0 0))))))))
  (void))

(define circular-wire-mesh
  (case-lambda
    [(diameter ribcount ringcount)
     (draw-circular-wire-mesh diameter #f ribcount ringcount #f)]
    [(outer-diameter inner-diameter ribcount ringcount)
     (draw-circular-wire-mesh
      outer-diameter inner-diameter ribcount ringcount #t)]))

(define (circular-shielded-reflector
         diameter height ribcount ringcount
         #:wall-ringcount [requested-wall-ringcount #f])
  "Draw a filled circular wire reflector with a cylindrical wire wall.

The reflector lies in the local forward/left plane and the wall rises HEIGHT
along local up. The floor has RIBCOUNT ribs and RINGCOUNT rings. Wall rings
are spaced evenly above the floor, including one at the top. When no wall ring
count is supplied, their spacing approximates the floor's radial ring spacing."
  ;; Validate before emitting the floor so a bad wall argument cannot leave a
  ;; partially constructed reflector in the model.
  (unless (positive-finite-real? diameter)
    (raise-argument-error
     'circular-shielded-reflector "positive finite real?" diameter))
  (unless (positive-finite-real? height)
    (raise-argument-error
     'circular-shielded-reflector "positive finite real?" height))
  (unless (and (exact-integer? ribcount) (>= ribcount 3))
    (raise-argument-error
     'circular-shielded-reflector
     "exact-integer? greater than or equal to 3"
     ribcount))
  (unless (exact-positive-integer? ringcount)
    (raise-argument-error
     'circular-shielded-reflector "exact-positive-integer?" ringcount))
  (unless (or (not requested-wall-ringcount)
              (exact-positive-integer? requested-wall-ringcount))
    (raise-argument-error
     'circular-shielded-reflector
     "#f or exact-positive-integer?"
     requested-wall-ringcount))

  (define radius (/ diameter 2))
  (define azimuth-step (/ 360 ribcount))
  (define wall-ringcount
    (or requested-wall-ringcount
        (max 1 (ceiling (/ height (/ radius ringcount))))))
  (define wall-step (/ height wall-ringcount))

  (circular-wire-mesh diameter ribcount ringcount)
  (call-from-here
   (lambda ()
     (wire-off)

     ;; Continue each floor rib up the wall, segmenting it wherever a
     ;; horizontal wall ring crosses.
     (call-with-radial-repeat
      ribcount
      (lambda ()
        (call-with-points
         (lambda ()
           (point-vector-local radius 0 0)
           (for ([wall-index (in-range 1 (add1 wall-ringcount))])
             (point-vector-local radius 0 (* wall-index wall-step)))))))

     ;; The floor's outer ring is already the bottom edge. Add the requested
     ;; courses above it, with the final course forming the top rim.
     (for ([wall-index (in-range 1 (add1 wall-ringcount))])
       (define z (* wall-index wall-step))
       (call-with-radial-repeat
        ribcount
        (lambda ()
          (call-with-points
           (lambda ()
             (point-vector-local radius 0 z)
             (turn-z azimuth-step)
             (point-vector-local radius 0 z))))))))
  (void))
