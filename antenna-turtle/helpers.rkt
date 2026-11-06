#lang racket/base

;; Common antenna-construction geometry that should not need to be reinvented
;; in each model.  Keep this module independent of the surface DSL: helpers
;; emit ordinary local wire geometry, so callers may freely wrap them in
;; with-surface or with-warp.

(require racket/math
         (only-in "private/core.rkt"
                  call-from-here
                  call-with-points
                  call-with-radial-repeat
                  point-vector-local
                  turn-z
                  wire-off))

(provide rectangular-wire-mesh
         circular-wire-mesh
         circular-shielded-reflector)

(define (positive-finite-real? value)
  (and (real? value)
       (not (nan? value))
       (not (infinite? value))
       (positive? value)))

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
