#lang antenna-turtle

(require "common.rkt")

;; A finite-diameter, center-fed dipole near its first resonance. The most
;; robust textbook target is peak directivity near 2.15 dBi.
(model title "Verification 10: free-space half-wave dipole"
       frequency 300 impedance 73
       max-length {wavelength / 80}
       wire-diameter {2 * millimeters})

(with-wire
  (with-scale 0.95
    (spread forward half-wave feed center)))

(module+ main
  (show-solid-model #:wire-segments 32)
  (define result
    (openems-sweep 250 350 #:steps 101 #:wire-segments 32
                   #:keep-artifacts? #t))
  (define resonant-frequency
    (frequency-of-minimum
     result (measurement-frequencies result)
     (lambda (sweep frequency) (s11-db-at sweep frequency))))
  (report-near "dipole resonance (MHz)" resonant-frequency 300
               #:relative 0.10)
  (define pattern
    (radiation-pattern result #:frequency resonant-frequency
                       #:theta-step 3 #:phi-step 3))
  (report-near "dipole peak directivity (dBi)"
               (maximum-gain pattern) 2.15 #:absolute 0.75)
  (show-return-loss-sweep result)
  (show-radiation-pattern-opengl pattern #:palette 'inferno))
