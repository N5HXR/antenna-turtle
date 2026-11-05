#lang antenna-turtle

(model title "80m Vertical Ground Plane"
       frequency 3.6
       ground real
       max-length {wavelength / 100})

(move up foot)
(with-scale 0.98
  (loop repeat 4 do
        (from-here (with-wire (move right quarter-wave)))
        (turn left 90))
  (wire-port feedpoint up anchor start gap {wavelength / 200})
  (from-here
    (move up {wavelength / 200})
    (with-wire (move up quarter-wave))))

(turn left 45)
(coax type rg58 output feedpoint
      (move forward {wavelength * 0.41}))

(show-model)

(define sweep (nec2c-vswr-sweep 3 4.5))
(show-return-loss-sweep sweep)

(define pattern (nec2c-radiation-grid))
(show-radiation-pattern-opengl pattern #:palette 'electric)

