#lang antenna-turtle

(require "common.rkt")

;; A 32-sided electrically small loop with circumference 0.1 wavelength. Its
;; normalized free-space directivity approaches the textbook 1.76 dBi.
(model title "Verification 11: electrically small loop"
       frequency 300 impedance 50
       max-length {wavelength / 200}
       wire-diameter {1 * millimeter})

(define sides 32)
(define perimeter (* 0.1 wavelength))
(define side-length (/ perimeter sides))

(with-wire
  (feed center)
  (loop repeat (sub1 sides)
        do (move forward side-length)
           (turn left (/ 360 sides)))
  (move-nearest))

(module+ main
  (show-solid-model #:wire-segments 24)
  (define result
    (openems-sweep 250 350 #:steps 101 #:wire-segments 24
                   #:keep-artifacts? #t))
  (define pattern
    (radiation-pattern result #:frequency 300
                       #:theta-step 3 #:phi-step 3))
  (report-near "small-loop peak directivity (dBi)"
               (maximum-gain pattern) 1.76 #:absolute 0.75)
  (show-smith-chart result)
  (show-radiation-pattern-opengl pattern #:palette 'inferno))
