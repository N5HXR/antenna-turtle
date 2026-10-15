#lang antenna-turtle

(model
 title "Meshtastic Cycloid Antenna Array"
 frequency 906
 wire-diameter (* 2 millimeters)
 max-length (half centimeter)
 impedance 200
)

;; A cycloid curl is roughly half a wavelength around its circumference.
(define radius (/ quarter-wave pi))

;; Trace one curl around the current vertical axis while rising slightly at
;; each vertex. Optionally place a feed halfway around the curl.
(define (curl fed?)
  (loop for segment from 1 to 36 do
	(turn left 10)
	(move up (/ wavelength 150))
	(if (and fed? (= segment 18))
	    (point left radius feed center)
	    (point left radius))))

;; Generate geometry for a collinear cycloid antenna array.
(define (cycloid)
  (with-scale 0.965
    (with-points
     (point left radius)
     (move up half-wave)
     (point left radius)
     (loop for curl-index from 1 to 3 do
	   (curl (= curl-index 2))
	   (move up half-wave)
	   (point left radius)))))

;; Report the wire needed to build one complete array.
(define mark (wire-used))
(from-here (cycloid))
(printf "Used ~a meters of wire.~n" (~r (- (wire-used) mark)))

(define impedance (nec2c-measure-impedance))
(define sweep (nec2c-vswr-sweep 800 1050 #:steps 201))
(define azimuth (nec2c-azimuth-pattern #:elevation 0 #:step 2))
(define sphere (nec2c-radiation-grid #:theta-step 1 #:phi-step 1))

(show-model)
(show-radiation-pattern-opengl sphere #:palette 'electric)
(show-smith-chart sweep)
