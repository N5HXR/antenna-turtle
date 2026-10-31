#lang antenna-turtle

(model-title "Realistic Dipole")
(model-frequency 14.1)
(maximum-segment-length (* 600 millimeters))
(wire-diameter (* 3 millimeters))

(move up (/ (model-wavelength) 4))
(display (/ (model-wavelength) 4))
(feed)
(with-push (with-pen (spread forward (* 1 feet))))

(loop repeat 2 do
      (with-push
	(move forward (/ foot 2))
	(turn down 60)
	(with-pen
	  (loop repeat 10 do
		(move forward (* 0.508 meter))
		(turn up 3))))
      (turn left 180))

(export-mmana "mmana/droopy-dipole.maa")


