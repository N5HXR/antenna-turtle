#lang antenna-turtle

(define wavelength (* 20 meter))
(define radiator (* 1/2 wavelength))
(define counterpoise (* 1/20 wavelength))

(model title "End-fed half-wave sloper with counterpoise"
       frequency 14.2
       max-length (/ wavelength 100)
       wire-diameter (* 2 millimeter))

;; Draw the radiator at 45 degrees above the XY plane. `from-here` returns the
;; turtle to the feed vertex afterward while retaining the generated wire.
;; Start/end feeds are supported by NEC2C and MMANA; MATLAB export rejects them.
(from-here
  (turn up 45)
  (with-wire
    (move forward radiator feed 'start)))

;; Counterpoise in the opposite horizontal direction from the feed vertex.
(turn left 180)
(with-wire
  (forward counterpoise))
