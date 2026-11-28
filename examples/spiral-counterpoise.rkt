#lang antenna-turtle

(model
 title "KL7AJ's Spiral Counterpoise"
 frequency 3.5
 impedance 50
 ground real
 wire-diameter {1.6 * millimeters}
 max-length {wavelength / 100})

(define (checklen start)
  (< (- (wire-used) start) {1 * quarter-wave}))

(with-scale 1.1
    (move up {12 * feet})
  (from-here (with-wire (move up {1 * quarter-wave} feed start)))

  (from-here
    (letrec ((wire-start (wire-used))
             (initial {1 * foot})
             (spacing initial))
      (move left spacing)
      (loop named spiral do
            (with-points
              (point right spacing)
              (loop repeat 12 do
                    (unless (checklen wire-start)
                      (return-from spiral '()))
                    (turn left 15)
                    (point right spacing)))
            (move left initial)
            (set! spacing (+ spacing initial))))))

(show-model)

;(define pattern (nec2c-radiation-grid))
;(define sweep (nec2c-vswr-sweep 3 4))
;(show-return-loss-sweep sweep)
;(show-radiation-pattern-opengl pattern)

;html-auto-report "spiral.html")
