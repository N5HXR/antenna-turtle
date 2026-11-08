#lang antenna-turtle

(model title "PETG-coated 70cm dipole"
       frequency 435
       max-length {wavelength / 40}
       wire-diameter {2 * millimeters})

(define petg
  (dielectric name petg
              er 3.2
              loss (narrow 0.015 435)))

;; Coating state applies to every subsequently created wire edge until it is
;; replaced or cleared. Its diameter is the dielectric's outside diameter;
;; wire-diameter above remains the metal diameter.
(wire-coating material petg diameter {12 * millimeters})

(with-wire
  (with-scale 1.03
    (spread forward half-wave feed center)))

(wire-coating-off)

(module+ main
  (show-model))
