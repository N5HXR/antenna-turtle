#lang antenna-turtle

;; An idealized hard impressed E-field source has no conductor or port. It
;; follows OpenEMS's infinitesimal-dipole excitation and is useful for
;; inspecting fields and cavity modes without modeling a physical coupling
;; probe. Consequently the result has no S11 or input impedance.
(model title "Ideal Electric Dipole"
       frequency 432)

(electric-dipole-source up
  name ideal-dipole
  length {wavelength / 20}
  amplitude 1)

(show-solid-model)

(define result
  (simulate
   engine openems
   sweep '(400 464)
   profile draft
   progress #f
   record-radiation #t
   record-fields
   (field-capture #:frequency 432
                  #:volume '(electric magnetic)
                  #:max-samples 250000)
   keep-artifacts #t))

(define pattern
  (radiation-pattern result #:frequency 432 #:theta-step 5 #:phi-step 5))

(show-radiation-pattern-opengl pattern #:palette 'electric)
(write-html-report result "ideal-electric-dipole.html")
