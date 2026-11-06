#lang antenna-turtle

(model title "Wire-frame parabolic dish"
       frequency 446
       max-length {wavelength / 20}
       wire-diameter {2 * millimeter})

;; ------------------------------------------------------------------------
;; Build a parabolic reflector
;; ------------------------------------------------------------------------

(define dish-radius {2 * wavelength})
(define focal-length {2.4 * wavelength})

(define rib-count 42)
(define ring-count 7)

;; Project a circular mesh onto a parabolic surface
(with-surface (paraboloid focal-length)
  (circular-wire-mesh {2 * dish-radius} rib-count ring-count))

;; ------------------------------------------------------------------------
;; Feedpoint Antenna -- a little yagi
;; ------------------------------------------------------------------------

(define element-layout
  (list (list 'reflector (* -0.6 quarter-wave) (* 1.05 half-wave))
        (list 'driven    0                     (* 1.00 half-wave))
        (list 'director  (* 0.6 quarter-wave)  (* 0.92 half-wave))))

;; A rudimentary dipole feed at the focus.
(from-here
  (move up focal-length)
  (loop for (role pos len) in element-layout do
	(from-here
	  (move down pos)
	  (with-scale 0.93
	    (with-wire
	      (when (eq? role 'driven) (feed center))
	      (spread left len))))))

;(export-mmana "mmana/dish.maa")
(show-model)
(define sweep (nec2c-vswr-sweep 400 500 #:steps 501))
