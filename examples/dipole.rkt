#lang antenna-turtle

(model title "Center-fed half-wave dipole"
       frequency 14.2
       max-length {wavelength / 100}
       wire-diameter {2 * millimeter})

;; `spread` creates one segment centered on the stationary turtle, so the feed
;; is exactly at the origin and the turtle remains there afterward.
(with-wire
  (spread forward half-wave feed 'center))
