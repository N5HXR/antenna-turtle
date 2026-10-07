#lang antenna-turtle

(model title "Center-fed half-wave dipole"
       frequency 14.2
       max-length {wavelength / 100}
       wire-diameter {2 * millimeter}
       ground perfect
       height (* 3.65 meter))

;; `spread` creates one segment centered on the stationary turtle, so the feed
;; is exactly at the origin and the turtle remains there afterward.
(with-wire
  (with-scale 0.95
    (spread forward half-wave feed center)))

(module+ main
  (define sweep (nec2c-vswr-sweep 5 20 #:steps 1001))
  (show-smith-chart sweep)
  ;; (show-return-loss-sweep sweep)
)
