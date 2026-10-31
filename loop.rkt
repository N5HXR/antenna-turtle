#lang antenna-turtle

(model-title "Full wave loop")
(model-frequency 14.1)
(maximum-segment-length (* 0.5 meter))
(wire-diameter (* 3 millimeter))

(define circ (* 20 meter))
(define dist (/ circ 30))

(with-pen
  (loop for i from 1 to 29 do
	(move forward dist)
	(turn left 12))
  (feed)
  (move-nearest))

(export-mmana "mmana/loop.maa")
	
