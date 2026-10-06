#lang antenna-turtle

(model
 title "Hanging Half-Wave Dipole"
 frequency 14.1
 max-length {wavelength / 100})

(define support-spacing half-wave)
(define center-sag {support-spacing / 8})
(define segment-count 40)
(define feed-segment (add1 (/ segment-count 2)))

;; A surface warp maps vertices rather than bending an edge, so emit enough
;; points to approximate the curve. The feed starts on the first segment after
;; the center vertex.
(with-surface (catenary support-spacing center-sag)
  (with-points
    (loop for index from 0 to segment-count do
          (let ([x {support-spacing
                    * (index / segment-count - 1 / 2)}])
            (if (= index feed-segment)
                (point forward x feed 'start)
                (point forward x))))))

(export-mmana "mmana/catenary-dipole.maa")

(show-model #:vertices? #t)
