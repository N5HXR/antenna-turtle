#lang antenna-turtle

(model
 title "Meshtastic Cycloid Antenna Array"
 frequency 906
 wire-diameter (* 2 millimeters)
 max-length (half centimeter))

;; cycloids want to be about half a wave long around the
;; circumference
(define radius (/ quarter-wave pi))

;; render a curl around the current vertical axis, holding the
;; vertices out at 'radius' length.
(define (curl fed?)
  (loop for i from 1 to 36 do
	(turn left 10)
	(move up (/ wavelength 150)); (* 2.2 millimeter))
	(if (and fed? (= i 18))
	    (point left radius feed 'center)
	    (point left radius))))

;; generate geometry for a collinear cycloid antenna array
(define (cycloid)
  (with-scale 0.979
    (with-points
     (point left radius)
     (move up half-wave)
     (point left radius)
     (loop for i from 1 to 3 do
	   (curl (= i 2))
	   (move up half-wave)
	   (point left radius)))))

;; in case we build it, we want to know how much wire there is
(define mark (wire-used))
(from-here (cycloid))
(printf "Used ~a meters of wire.~n" (~r (- (wire-used) mark)))

(export-mmana "mmana/cycloid.maa")
