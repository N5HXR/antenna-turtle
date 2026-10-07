#lang antenna-turtle

(model
 title "Meshtastic Franklin Array"
 wire-diameter (* 1.63 millimeter)  ;; 14AWG wire
 frequency 915)

;; some antenna design parameters
(define element-count 1)

;; empirically determined tuning parameters
(define tune-stub 0.9)
(define tune-scale 1.071)

;; franklin arrays use tuning stubs to align collinear elements
(define stub-length (* tune-stub quarter-wave))
(define stub-width centimeter)

;; try a parallel matching stub
(define mlen (- quarter-wave (* 8 millimeters)))
(define mid (* 12 millimeters))
(define rest (- mlen mid))

(define mh (* 3 millimeters))
(define mhh (half mh))

(with-scale tune-scale
  (from-here
    (move up mhh)
    (with-wire
      (move right rest)
      (from-here (move down mh feed 'center))5
      (move right mid)
      (move down mh)
      (move left mid)
      (move left rest)))

;; construct a franklin array
  (reflect up
    (move up mhh)
    (with-wire
      (move up (- half-wave mhh))
      (loop repeat element-count do
	    (move left stub-length)
	    (move up stub-width)
	    (move right stub-length)
	    (move up half-wave)))))

;; test in MMANA-GAL
(export-mmana "mmana/franklin.maa")
