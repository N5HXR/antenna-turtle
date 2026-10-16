#lang antenna-turtle

;; Differential two-conductor line fixture.  This is intentionally simple:
;; it exists to validate traveling-current phase and solver/user coordinate
;; alignment, not to define a production transmission-line port abstraction.
(define length 100)
(define separation 6)
(define width 2)

(define (build-model)
  (model title "HTML report fixture: two-conductor line"
         frequency 1000 impedance 100)
  (with-scale millimeters
    (with-material copper
      (from-here
        (move back (half length) left (half separation))
        (with-traces width (move forward length)))
      (from-here
        (move back (half length) right (half separation))
        (with-traces width (move forward length)))
      (from-here
        (move back (half length))
        (port left name input gap separation size (list width 1) anchor center))
      (from-here
        (move forward (half length))
        (port left name output gap separation size (list width 1) anchor center)))))

(build-model)

(module+ main
  (reset-model!)
  (build-model)
  (define report-fixture
    (derive-simulation-profile
     standard #:name 'report-fixture #:frequency-steps 61
     #:maximum-timesteps 60000 #:end-criteria 1e-3))
  (define result
    (simulate
     engine openems
     sweep '(850 1150)
     profile report-fixture
     progress #f
     record-radiation #f
     record-fields
     (field-capture
      #:frequency 1000
      #:excitation 'input
      #:current 'conductors
      #:volume '(electric magnetic))
     keep-artifacts #t))
  (define report
    (write-html-report result "scratch/html-report-m1-two-conductor.html"))
  (printf "Portable report: ~a\n" report))
