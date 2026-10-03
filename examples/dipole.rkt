#lang antenna-turtle

(define wavelength (* 20 meter))
(define total-length (* 1/2 wavelength))

(model-title "Center-fed half-wave dipole")
(maximum-segment-length (/ wavelength 100))
(model-frequency 14.2)
(wire-diameter (* 2 millimeter))

;; `spread` creates one segment centered on the turtle. It silently moves to
;; the -X endpoint and then draws toward +X, so the feed is exactly at origin.
(feed)
(with-pen
  (spread forward total-length))
