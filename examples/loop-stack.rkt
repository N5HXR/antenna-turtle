#lang antenna-turtle

(model title "Stacked full-wave polygon loops"
       frequency 150.0
       max-length (/ wavelength 120)
       wire-diameter (* 3 millimeter))

(define (regular-loop sides perimeter fed?)
  (define side-length (/ perimeter sides))
  (define exterior-angle (/ 360 sides))
  (from-here
    (with-wire
      (when fed? (feed 'center))
      ;; Draw all but the closing side. `move-nearest` then clones the exact
      ;; starting coordinate, avoiding a nearly-closed floating-point loop.
      (loop repeat (sub1 sides)
            do (forward side-length)
               (turn left exterior-angle))
      (move-nearest))))

;; Each completed loop leaves the turtle where it started. Unwired moves place
;; subsequent loops one-quarter wavelength higher on local +Z.
(regular-loop 4 wavelength #t)
(move up quarter-wave)
(regular-loop 8 wavelength #f)
(move up quarter-wave)
(regular-loop 32 wavelength #f)
