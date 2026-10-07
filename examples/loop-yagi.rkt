#lang antenna-turtle

(model
 title "Loop Yagi"
 wire-diameter millimeter
 frequency 438)

;; Reference radius for the loops.
(define loop-radius {wavelength / (2 * pi)})

;; Trace points in a circle at the requested radius.
(define (loop-element radius fed?)
  (with-points
    (point right radius)
    (when fed? (feed start))
    (loop repeat 36 do
	  (turn roll-left 10)
	  (point right radius))))

;; The reflector is a bit bigger.
(loop-element (* loop-radius 1.04) #f)

;; Empirically tuned distance to the driven element.
(move forward (* 0.70 quarter-wave))

;; Driven element.
(loop-element (* loop-radius 0.99) #t)

;; Place seven directors.
(loop repeat 7 do
      (move forward (* 1.15 quarter-wave))
      (loop-element (* loop-radius 0.95) #f))

(export-mmana "mmana/loop-yagi.maa")
