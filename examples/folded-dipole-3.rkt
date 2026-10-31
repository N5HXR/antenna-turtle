#lang antenna-turtle

(model
 title "Folded Dipole"
 frequency 14.1
 ground real)

(move up 10)

(with-wire
  (move forward half-wave feed center)
  (move up (half foot))
  (move backward half-wave)
  (move down (half foot)))

(show-model)

(define s (nec2c-vswr-sweep 12 16 #:steps 201))
(show-return-loss-sweep s)
(show-smith-chart s)
