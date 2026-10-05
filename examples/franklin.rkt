#lang antenna-turtle

(model
 title "Meshtastic Franklin Array"
 frequency 915)

;; some antenna design parameters
(define element-count 1)

;; empirically determined tuning parameters
(define tune-stub 1.05) 
(define tune-scale 1.02)

;; franklin arrays use tuning stubs to align collinear elements
(define stub-length (* tune-stub quarter-wave))
(define stub-width (half centimeter))

;; construct a franklin array
(with-scale tune-scale
  (from-here (with-wire (spread up half-wave feed 'center)))
  (reflect up
    (move up quarter-wave)
    (with-wire
      (loop repeat element-count do
	    (move left stub-length)
	    (move up stub-width)
	    (move right stub-length)
	    (move up half-wave)))))

;; test in MMANA-GAL
(export-mmana "mmana/franklin.maa")
