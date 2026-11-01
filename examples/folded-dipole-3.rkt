#lang antenna-turtle

(model
 title "Folded Dipole"
 frequency 14.1
 ground real
 max-length {wavelength / 100})

(define leg (* 0.93 half-wave))

(move up 10)

(with-wire
  (move forward leg feed center)
  (move up (* 2/3 meter))
  (move backward leg)
  (move down (* 2/3 meter)))

(show-model)

(define s (nec2c-vswr-sweep 12 16 #:steps 201))
(show-return-loss-sweep s)
(show-smith-chart s)
(html-auto-report "scratch/folded-dipole-3.html")
