#lang antenna-turtle

(model
 title "915 MHz microstrip patch"
 frequency 915
 impedance 50)

(define substrate '(150 150 1.6))
(define patch '(89 70))
(define h 1.6)

(with-scale millimeters
  (with-material fr4
    (cuboid size '(150 150 1.6) anchor 'bottom))

  (with-material copper
    (sheet rect size '(150 150))
    (from-here
      (move up 1.6)
      (sheet rect size patch)))

  (from-here
    (move left 13)
    (port up gap h size '(2 2) anchor start)))

(define result
  (simulate engine openems
            sweep '(800 1050)
            profile draft))

(define pattern (openems-radiation-grid result))
(show-radiation-pattern-opengl pattern #:palette 'electric)
(show-solid-model)
