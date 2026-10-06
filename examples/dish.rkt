#lang antenna-turtle

(model title "Wire-frame parabolic dish"
       frequency 446
       max-length {wavelength / 20}
       wire-diameter {2 * millimeter})

(define dish-radius {2 * wavelength})
(define focal-length {2.4 * wavelength})

(define rib-count 42)
(define ring-count 7)
(define azimuth-step {360 / rib-count})

(define (dish-height radius)
  {radius * radius / {4 * focal-length}})

;; One radial wire, with vertices at every ring crossing.
(define (rib azimuth)
  (from-here
    (turn left azimuth)
    (with-points
      (loop for index from 0 to ring-count do
	    (let ([radius {dish-radius * index / ring-count}])
	      (point forward radius
		     up (dish-height radius)))))))

;; One polygonal approximation of a circular ring.
(define (ring radius)
  (define height (dish-height radius))
  (from-here
    (with-points
      (point forward radius up height)

      (loop repeat rib-count do
	    (turn left azimuth-step)
	    (point forward radius up height)))))

;; Radial ribs.
(loop for index from 0 below rib-count do
      (rib {index * azimuth-step}))

;; Concentric rings. Skip radius zero.
(loop for index from 1 to ring-count do
      (ring {dish-radius * index / ring-count}))

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

;(show-model #:vertices? #t)
