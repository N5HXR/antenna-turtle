#lang antenna-turtle

;; Regenerable Milestone 1 fixture for the portable HTML report.  Generated
;; solver and report artifacts belong under scratch/ and are intentionally not
;; checked into Git.
(define (build-model)
  (model title "HTML report fixture: half-wave dipole"
         frequency 1000 impedance 73
         max-length {wavelength / 55})
  (define total-length (* 0.95 (/ (model-wavelength) 2) 1000))
  (define feed-gap 1)
  (define arm-length (/ (- total-length feed-gap) 2))
  (with-scale millimeters
    (with-material pec
      (from-here
        (move back (half feed-gap))
        (with-traces 2 (move back arm-length)))
      (from-here
        (move forward (half feed-gap))
        (with-traces 2 (move forward arm-length)))
      ;; Match the lumped port to the zero-thickness PEC sheet.  Giving this
      ;; idealized feed a copper-foil depth would force a 17.5 um Yee cell and
      ;; an unnecessarily tiny Courant timestep throughout the large domain.
      (port forward name feed-1 gap feed-gap size (list 2 0)
            anchor center))))

(build-model)

(module+ main
  (reset-model!)
  (build-model)
  ;; This fixture checks report geometry, phasor animation, and portability;
  ;; it does not need the production profile's -50 dB convergence target.
  (define report-fixture
    (derive-simulation-profile
     standard #:name 'report-fixture #:frequency-steps 61
     #:maximum-timesteps 60000 #:end-criteria 1e-3
     ;; Retain enough free space to watch the near field become radiative.
     #:padding-wavelengths 1.5))
  (define result
    (simulate
     engine openems
     sweep '(850 1150)
     profile report-fixture
     progress #f
     record-radiation #f
     record-fields
     (field-capture #:frequency 1000
                    #:current 'conductors
                    #:volume '(electric magnetic)
                    #:max-samples 500000)
     keep-artifacts #t))
  (define report
    (write-html-report result "scratch/html-report-m1-dipole.html"))
  (printf "Portable report: ~a\n" report))
