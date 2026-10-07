#lang antenna-turtle

(model frequency 915)

(define (stub length width)
  (with-wire
    (move left length)
    (move up width)
    (move right length)))

(define (unit vertical slen swidth)
  (stub slen swidth)
  (with-wire
    (move up vertical)))

(define (dipole length)
  (let* ([stub (* 0.925 (/ (model-wavelength) 2))]
	 [fraction 0.78]
	 [feedpoint (* stub fraction)]
	 [remainder (- stub feedpoint)])
    (from-here
      (move up (/ centimeter 2))
      (with-wire
	(move right feedpoint)
	(from-here
	  (move down centimeter feed 'center))
	(move right remainder)
	(move down centimeter)
	(move left stub)
	(move down (/ length 2))))
    (move up (/ centimeter 2))
    (with-wire
      (move up (/ length 2)))))

(define (franklin-array dlen ulen slen swidth count)
  (dipole dlen)
  (from-here
    (loop for i from 1 to count do
	  (unit ulen slen swidth)))
  (move down (+ centimeter dlen))
  (turn down 180)
  (loop for i from 1 to count do
	(unit ulen slen swidth)))

(define half-wave (/ (model-wavelength) 2))
(define quarter-wave (/ (model-wavelength) 4))
(define dipole-length half-wave)
(define radiator-length half-wave)
(define stub-width (* 13 millimeters))
(define stub-length (- quarter-wave (/ stub-width 2)))
(define unit-count 2)

(display radiator-length)

(with-scale 1.059
  (franklin-array
   dipole-length
   radiator-length
   (* stub-length 0.96)
   stub-width
   unit-count))

(export-mmana "mmana/franklin.maa")
