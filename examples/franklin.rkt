#lang antenna-turtle

(model
 title "Meshtastic Franklin Array"
 frequency 915)

;; some antenna design parameters
(define element-count 3)

;; empirically determined tuning parameters
(define tune-stub 1.03) 
(define tune-scale 0.98)

;; franklin arrays use tuning stubs to align collinear elements
(define stub-length (* tune-stub quarter-wave))
(define stub-width centimeter)

;; construct a franklin array
(with-scale tune-scale
  (reflect up
    (with-wire
      (move up quarter-wave feed 'start)
      (loop repeat element-count do
	    (move left stub-length)
	    (move up stub-width)
	    (move right stub-length)
	    (move up half-wave)))))

;; test in MMANA-GAL
(export-mmana "mmana/franklin.maa")
