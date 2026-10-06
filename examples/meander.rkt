#lang antenna-turtle

(model
 title "Meander Experiment"
 frequency 915)

(with-wire
  (spread up half-wave feed 'center))
(reflect up
  (move up quarter-wave)
  (with-wire
    (loop repeat 3 do
	  (move right half-wave)
	  (move up half-wave)
	  (move left half-wave)
	  (move up half-wave))))

(export-mmana "mmana/meander.maa")
