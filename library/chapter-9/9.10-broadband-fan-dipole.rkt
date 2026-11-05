#lang antenna-turtle

(define segment-factor 200)

(model title "Broadband 80m Fan Dipole"
       frequency 3.75
       max-length {wavelength / segment-factor}
       wire-diameter {3 * millimeter}
       impedance 50)

(define segment (/ wavelength segment-factor))
(define medium (* 0.96 quarter-wave))
(define short (* 1.0 medium (/ 3.75 4.0)))
(define long (* 1.0 medium (/ 3.75 3.5)))

(move up half-wave)

;(with-wire (spread forward segment port (feedpoint gap segment)))
(with-wire (spread forward segment feed center))

(from-here
  (reflect forward
    (move forward (half segment))
    (with-scale 0.85
      (turn down 10)
      (loop for len in (list short medium long) do
            (from-here (with-wire (forward len)))
            (turn up 10)))))

;(coax type rg6 output feedpoint
;      (move down (- half-wave foot)))

;(show-model)
(define sweep (nec2c-vswr-sweep 3 4.5 #:steps 301))
(show-return-loss-sweep sweep)
(show-smith-chart sweep)
;write-s1p "9.10-broadband-fan-dipole.s1p" sweep)
