#lang antenna-turtle

(model title "Illustrative Moxon rectangle geometry"
       frequency 29.0
       max-length (/ wavelength 120)
       wire-diameter (* 2 millimeter))

(define long-side (* 0.36 wavelength))
(define folded-end (* 0.055 wavelength))
(define spacing (* 0.14 wavelength))

(define (bent-element length bend inward-turn driven?)
  ;; Isolate the element's positioning and heading from the surrounding model.
  (from-here
    (move back (half length))
    (with-wire
      (turn right inward-turn)
      (forward bend)
      (turn left inward-turn)
      (when driven? (feed center))
      (forward length)
      (turn left inward-turn)
      (forward bend))))

;; The driven element is centered at the origin. Move directly along local +Y
;; to place the reflector, whose folds face the opposite direction.
(bent-element long-side folded-end 90 #t)
(move left spacing)
(bent-element (* 1.02 long-side) folded-end -90 #f)
