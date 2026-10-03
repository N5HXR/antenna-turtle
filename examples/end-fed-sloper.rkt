#lang antenna-turtle

(define wavelength (* 20 meter))
(define radiator (* 1/2 wavelength))
(define counterpoise (* 1/20 wavelength))
(define feed-edge (/ wavelength 200))

(model-title "End-fed half-wave sloper with counterpoise")
(maximum-segment-length (/ wavelength 100))
(model-frequency 14.2)
(wire-diameter (* 2 millimeter))

;; Draw the radiator at 45 degrees above the XY plane. `with-push` returns the
;; turtle to the feed vertex afterward while retaining the generated wire.
(with-push
  (turn up 45)
  (with-pen
    (feed)
    (forward feed-edge)
    (forward (- radiator feed-edge))))

;; Counterpoise in the opposite horizontal direction from the feed vertex.
(turn left 180)
(with-pen
  (forward counterpoise))
