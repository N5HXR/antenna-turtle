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
(define azimuth-step {360 / rib-count})
(define ring-step (/ dish-radius ring-count))

;; One radial wire, with vertices at every ring crossing.
(define (rib)
  (from-here
    (with-wire
      (move forward dish-radius steps ring-count))))

(define (ring radius)
  ;; Each radial copy emits one complete chord. Adjacent endpoints snap to the
  ;; same model vertex, including the final chord back to the first.
  (radial-repeat rib-count
    (with-points
      (point forward radius)
      (turn left azimuth-step)
      (point forward radius))))

;; Project a circular mesh onto a parabolic surface
(with-surface (paraboloid focal-length)
  (radial-repeat rib-count (rib))
  (loop for index from 1 to ring-count do
	(ring {index * ring-step})))

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
	      (when (eq? role 'driven) (feed 'center))
	      (spread left len))))))

(export-mmana "mmana/dish.maa")

(show-model #:vertices? #t)
