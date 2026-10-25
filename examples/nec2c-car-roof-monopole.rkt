#lang antenna-turtle

;; Rev-1 NEC2 MFIE surface-body example: a 5/8-wave monopole mounted near the
;; center of a deliberately simple three-volume automobile body.  The three
;; overlapping cuboids are unioned by Manifold before their closed exterior is
;; resampled as a regular, body-local patch lattice.
(model title "1.25 m 5/8-wave car-roof monopole"
       frequency 222
       max-length (/ wavelength 30)
       nec2-patch-length (/ wavelength 5)
       wire-diameter (* 6 millimeter)
       impedance 50
       ground (real 13 0.005))

(move down 0.5)

(with-body name vehicle form surface material pec anchor origin
  ;; Hood, cabin, and trunk overlap so their union is one closed manifold.
  (from-here
    (move forward 1.45)
    (move up 0.75)
    (cuboid size '(1.7 1.7 0.5)))
  (from-here
    (move up 1.15)
    (cuboid size '(2.2 1.7 0.9)))
  (from-here
    (move backward 1.45)
    (move up 0.8)
    (cuboid size '(1.2 1.7 0.6))))

;; The authored base is at the roof center.  If necessary, NEC export translates
;; this whole connected wire assembly by the small offset to the nearest patch
;; centroid, preserving the monopole's length and orientation.
(from-here
  (move forward 1.45 up 1.0)
  (turn up 90)
  (with-wire
    (move forward (* 1.24 5/8 wavelength) feed start)))

(module* main #f
 (#%plain-module-begin
  ;; Surface patches add two dense-matrix unknowns apiece, so this intentionally
  ;; uses a modest first-look sweep and pattern grid.
  (define sweep (nec2c-vswr-sweep 200 240 #:steps 41))
  (display (format "Impedance: ~a~n" (impedance-at sweep 222)))
  (define pattern
    (nec2c-radiation-grid #:frequency 222 #:theta-step 5 #:phi-step 5))
  (show-smith-chart sweep)
  (show-solid-model)
  (write-html-report
   sweep "nec2c-car-roof-monopole.html" #:pattern pattern)))
