#lang antenna-turtle

(model
 title "KL7AJ's Spiral Counterpoise"
 frequency 3.5
 impedance 120
 ground real
 wire-diameter {1.6 * millimeters}
 max-length {wavelength / 100})

(define (spiral-arm length radial-step angle-step)
  (from-here
    (let ((wire-start (wire-used))
          (radius 0)
          (angle 0))

      (with-points
        ;; All arms share this center vertex.
        (point forward 0)

        (loop named arm do
          (set! radius (+ radius radial-step))
          (set! angle (+ angle angle-step))

          ;; Absolute polar point relative to the unchanged turtle.
          (point forward (* radius (cos angle))
                 left    (* radius (sin angle)))

          (when (>= (- (wire-used) wire-start) length)
            (return-from arm (void))))))))

(define (multi-start-spiral starts arm-length inter-arm-spacing
                            #:segments-per-turn (segments 18))
  (let* ((angle-step (/ (* 2 pi) segments))

         ;; An arm passes all STARTS tracks before its next revolution.
         (arm-pitch (* starts inter-arm-spacing))
         (radial-step (/ arm-pitch segments)))

    (radial-repeat starts
      (spiral-arm arm-length radial-step angle-step))))

(with-scale 0.8
  (move up foot)
  (from-here
    (turn down 10)
    (with-wire (move up quarter-wave feed start)))
  (from-here
    (turn up 10)
    (with-wire (move up quarter-wave)))
  (multi-start-spiral 3 quarter-wave {meter}))

(show-model)

(define pattern (nec2c-radiation-grid))
(define sweep (nec2c-vswr-sweep 3 4))
(show-return-loss-sweep sweep)
;(show-radiation-pattern-opengl pattern)
(power-report pattern)

;html-auto-report "spiral.html")
