#lang antenna-turtle

(define wavelength (* 20 meter))
(define height (* 1/4 wavelength))

(model title "Quarter-wave vertical geometry"
       frequency 14.2
       max-length (/ wavelength 100)
       wire-diameter (* 2 millimeter))

;; Pitch local forward from +X to +Z. The start feed puts the source at the
;; intended ground-plane attachment point. Ground itself is added in the
;; target simulator, not in the geometry DSL. Start feeds target NEC2C/MMANA;
;; MATLAB export rejects them.
(turn up 90)
(with-wire
  (move forward height feed 'start))
