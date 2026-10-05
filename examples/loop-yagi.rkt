#lang antenna-turtle

(model
 title "Loop Yagi"
 wire-diameter millimeter
 frequency 438)

;; reference radius for the loops
(define loop-rad (/ (* 1.0 wavelength) pi 2))

;; trace points in a circle at the radius
(define (loop-element radius fed?)
  (with-points
    (point right radius)
    (when fed? (feed 'start))
    (loop repeat 36 do
	  (turn roll-left 10)
	  (point right radius))))

;; reflector is a bit bigger
(loop-element (* loop-rad 1.04) #f)

;; empirically tuned distance to driven element
(move forward (* 0.70 quarter-wave))

;; driven element 
(loop-element (* loop-rad 0.99) #t)

;; place 7 directors
(loop repeat 7 do
      (move forward (* 1.15 quarter-wave))
      (loop-element (* loop-rad 0.95) #f))

(export-mmana "mmana/loop-yagi.maa")
