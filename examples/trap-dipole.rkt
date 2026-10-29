#lang antenna-turtle

(model title "Trap Dipole"
       frequency 10.1)

(with-wire (spread up inch feed center))

(reflect up
  (move up (half inch))
  (with-wire
    (move up quarter-wave)
    (lumped-element up
      gap inch
      topology parallel
      capacitance 59e-12
      inductance 4000e-9
      resistance 12.7e3)
    (move up {2.0 * meters})))
(show-model)

(define sweep (nec2c-vswr-sweep 3.5 20 #:steps 1001))
(show-return-loss-sweep sweep)
(show-smith-chart sweep)
