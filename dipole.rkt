#lang antenna-turtle

(model-title "Realistic Dipole")
(model-frequency 14.1)
(maximum-segment-length (* 200 millimeters))
(wire-diameter (* 3 millimeters))

(move up (/ (model-wavelength) 4))
(display (/ (model-wavelength) 4))
(feed)
(with-push (with-pen (spread forward (/ (model-wavelength) 2.06))))

(export-mmana "mmana/straight-dipole.maa")


