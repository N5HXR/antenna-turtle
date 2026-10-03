#lang antenna-turtle

(define wavelength (* 20 meter))
(define height (* 1/4 wavelength))
(define feed-edge-length (/ wavelength 200))

(model-title "Quarter-wave vertical geometry")
(maximum-segment-length (/ wavelength 100))
(model-frequency 14.2)
(wire-diameter (* 2 millimeter))

;; Pitch local forward from +X to +Z. The short fed edge puts the source just
;; above the intended ground-plane attachment point. Ground itself is added in
;; the target simulator, not in the geometry DSL.
(turn up 90)
(with-pen
  (feed)
  (forward feed-edge-length)
  (forward (- height feed-edge-length)))
