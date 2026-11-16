#lang antenna-turtle

(require "common.rkt")

;; The finite-diameter, center-fed article used for the NEC2C/OpenEMS wire
;; comparison. Keep these dimensions synchronized with the physical build.
(model title "Verification 10: 432 MHz wire-reference dipole"
       frequency 432 impedance 73
       max-length {wavelength / 80}
       wire-diameter {3 * millimeters})

(with-wire
  (with-scale 0.94
    (spread forward half-wave feed center)))

(show-solid-model #:wire-segments 32)
(define estimate
  (simulate engine openems sweep '(380 470) profile wire-reference
            dry-run #t progress #f keep-artifacts #f))
(printf "wire-reference dry run: ~a cells\n"
        (openems-dry-run-cell-count estimate))
(define result
  (simulate engine openems sweep '(380 470) profile wire-reference
            keep-artifacts #t))
(define resonant-frequency
  (frequency-of-minimum
   result (measurement-frequencies result)
   (lambda (sweep frequency) (s11-db-at sweep frequency))))
(report-near "dipole resonance (MHz)" resonant-frequency 432
             #:relative 0.10)
(define pattern
  (radiation-pattern result #:frequency resonant-frequency
                     #:theta-step 3 #:phi-step 3))
(report-near "dipole peak directivity (dBi)"
             (maximum-gain pattern) 2.15 #:absolute 0.75)
(show-return-loss-sweep result)
(show-radiation-pattern-opengl pattern #:palette 'inferno)
