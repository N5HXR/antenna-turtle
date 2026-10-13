#lang antenna-turtle

(model
 title "Transmission Line"
 frequency 1000)

(define trace-width 3.1)

(with-scale millimeters
  (with-material fr4
    (cuboid size '(80 50 1.6) anchor bottom))
  (with-material copper
    (sheet rect size '(80 50))
    (move back 20)
    (port up name input gap 1.6 size trace-width anchor start)
    (move up 1.6)
    (with-traces trace-width
      (move forward 40))
    (port up name output gap 1.6 size trace-width anchor end)))

(show-solid-model)

(define sweep
  (simulate engine openems
            sweep '(900 1100)
            profile draft
            keep-artifacts #t))

(define z0 (characteristic-impedance-at sweep 1000))

(display (format "~a~n" z0))
