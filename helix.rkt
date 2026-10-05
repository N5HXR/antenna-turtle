#lang antenna-turtle

(define freq 446) ;; megahertz

;; Document info

(model title         "Helical antenna"
       frequency     freq
       max-length    {50 * millimeter}
       wire-diameter {3 * millimeter})

(define wave    (span wavelength millimeter)) ;; wavelength in objective mm
(define diam    200)                          ;; design diameter of helix
(define circ    {diam * pi})                  ;; calculated circumference
(define seg-per 12)                           ;; segments per turn
(define seg     {circ / seg-per})             ;; distance per segment
(define angle   {360 / seg-per})              ;; turn angle per segment
(define pitch   {wave / 6})                   ;; fraction of wavelength between turns
(define dz      {pitch / seg-per})            ;; portion of pitch per segment
(define turns   5)                            ;; how many turns to generate

(define (helix)
  (let [(ldz dz)]
    (with-scale {1.24 * millimeter}
      (with-wire
	(move up 20 feed 'center)
	(loop for i from 1 to {turns * seg-per} do
	      (move forward seg up ldz)
	      (turn left angle)
	      (set! ldz {ldz * 1.02})
	      )))))

(define dist {0.5 * meter})

(loop for i from 1 to 4 do
      (from-here
	(turn left {i * 90})
	(move forward dist)
	(turn right {i * 90})
	(helix)))


(export-mmana "mmana/helix.maa")
