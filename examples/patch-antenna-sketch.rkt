#lang antenna-turtle

(model "915 MHz microstrip patch"
  frequency 915
  impedance 50)

(define substrate '(150 150 1.6))
(define patch '(89 70))
(define h 1.6)

(with-units millimeters
  (with-material (dielectric er 4.4)
    (box substrate anchor 'bottom))

  (with-material pec
    (sheet-rect (take substrate 2) name ground
                mesh-edges exact)

    (from-here
      (move up h)
      (sheet-rect patch name patch
                  mesh-edges metal)))

  (from-here
    (move up (/ h 2) left -13)
    (port up name feed
          gap h size '(2 2))))

(define result
  (simulate engine openems
            sweep '(800 1050)
            quality draft))

