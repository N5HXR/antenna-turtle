#lang antenna-turtle

(define wavelength {20 * meter})
(define total-length {wavelength / 2})

(model title "Center-fed half-wave dipole"
       frequency 14.2
       max-length {wavelength / 100}
       wire-diameter {2 * millimeter})

;; `spread` creates one segment centered on the turtle. It silently moves to
;; the -X endpoint and then draws toward +X, so the feed is exactly at origin.
(with-wire
  (spread forward total-length feed 'center))
