#lang antenna-turtle

(require "common.rkt")

;; A closed rectangular PEC cavity excited by a short internal dipole. For the
;; 150 x 80 x 200 mm inner volume, TE101 is approximately 1.249 GHz:
;; f101 = c/2 * sqrt((1/a)^2 + (1/d)^2).
(model title "Verification 13: rectangular PEC cavity"
       frequency 1250 impedance 50
       max-length {wavelength / 60}
       wire-diameter {2 * millimeters})

(define inner-length 150)
(define inner-width 80)
(define inner-height 200)
(define wall-thickness 2)
(define expected-te101 1249)

(with-scale millimeters
  ;; Export the surviving inner and outer CSG boundaries as native PEC
  ;; surfaces. A hollow STL volume does not expose its wall thickness to the
  ;; revision-1 solid-body mesh guarantee.
  (with-body name cavity form surface
    (difference
     (cuboid size (list (+ inner-length (* 2 wall-thickness))
                        (+ inner-width (* 2 wall-thickness))
                        (+ inner-height (* 2 wall-thickness))))
     (cuboid size (list inner-length inner-width inner-height))))
  ;; The dominant TE101 electric field is transverse to the long dimension.
  (with-wire
    (spread left 30 feed center)))

(module+ main
  (show-solid-model #:wire-segments 24)
  (define result
    (openems-sweep 900 1500 #:steps 151 #:wire-segments 24
                   #:keep-artifacts? #t))
  (define cavity-resonance
    (frequency-of-minimum
     result (measurement-frequencies result)
     (lambda (sweep frequency) (s11-db-at sweep frequency))))
  (report-near "TE101 cavity resonance (MHz)"
               cavity-resonance expected-te101 #:relative 0.05)
  (show-return-loss-sweep result)
  (show-smith-chart result))
