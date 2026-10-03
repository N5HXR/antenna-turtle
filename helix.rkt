#lang antenna-turtle

(define freq 446) ;; megahertz

;; Document info

(model-title "Helical antenna")
(maximum-segment-length (* 10 millimeter))
(model-frequency freq)
(wire-diameter (* 3 millimeter))

(define wave    (* 1000 (/ 300 freq) meter))  ;; wavelength in mm
(define diam    223)                          ;; design diameter of helix
(define circ    (* diam pi))                  ;; calculated circumference
(define seg-per 24)                           ;; segments per turn
(define seg     (/ circ seg-per))             ;; distance per segment
(define angle   (/ 360 seg-per))              ;; turn angle per segment
(define pitch   (/ wave 8))                   ;; fraction of wavelength between turns
(define dz      (/ pitch seg-per))            ;; portion of pitch per segment
(define turns   5)                            ;; how many turns to generate

;; Tuned to the 1.015 factor after simulation for resonance at 446MHz
(with-scale (* 1.24 millimeter)

  ;; we'll draw elements the whole way
  (with-pen

    ;; first element is the 'stem' with the feedpoint
    (feed)
    (move up 20)

    ;; generate our turns in a loop
    (loop for i from 1 to (* turns seg-per) do
	  (move forward seg up dz)
	  (turn left angle)

	  ;; playing with progressively increasing pitch?
	  (set! dz (* dz 1.01))
	  )))

(export-mmana "mmana/helix.maa")
