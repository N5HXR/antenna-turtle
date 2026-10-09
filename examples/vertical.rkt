#lang antenna-turtle

(model title "Quarter-wave vertical geometry"
       frequency 14.2
       max-length (/ wavelength 20)
       wire-diameter (* 2 millimeter))

;; Pitch local forward from +X to +Z. The start feed puts the source at the
;; ground-plane attachment point. With grounded NEC2C models, GE 1 connects
;; that endpoint to its image. Start feeds target NEC2C/MMANA; MATLAB export
;; rejects them.
(from-here
  (turn up 90)
  (with-wire
    (move forward quarter-wave feed start)))
(loop repeat 36 do
      (turn left 10)
      (with-points
        (point left 0)
        (point left wavelength)))

(export-mmana "mmana/vertical.maa")

(define sphere
  (nec2c-radiation-grid #:theta-step 0.5 #:phi-step 0.5))

(show-radiation-pattern-opengl sphere #:scale 'db #:palette 'inferno)
