#lang antenna-turtle

;; Milestone 4 PCB fixture, translated directly from
;; examples/verification/00-matched-microstrip.rkt.  The transparent FR-4
;; volume, ground plane, top trace, and two ports exercise material geometry,
;; conductor current/charge, and full-volume E/H and power presentation in one
;; portable report.
(define substrate-height 1.6)
(define trace-width 3.1)
(define line-length 40)

(define (build-model)
  (model title "HTML report fixture: matched microstrip PCB"
         frequency 1000 impedance 50)

  (define substrate (dielectric name lossless-fr4 er 4.4))
  (with-scale millimeters
    (with-material substrate
      (cuboid name substrate size '(80 50 1.6) anchor bottom))
    (with-material copper
      (sheet rect name ground size '(80 50))
      (move back (half line-length) up substrate-height)
      (port up name input gap substrate-height size trace-width anchor end)
      (with-traces trace-width (move forward line-length))
      (port up name output gap substrate-height size trace-width anchor end))))

(build-model)

(module+ main
  (reset-model!)
  (build-model)
  (define report-fixture
    (derive-simulation-profile
     standard #:name 'matched-microstrip-report-fixture
     #:frequency-steps 61
     #:maximum-timesteps 80000 #:end-criteria 1e-3
     ;; Leave enough surrounding air to distinguish the guided field from
     ;; fringing and any unintended radiation without making this compact PCB
     ;; verification model into a far-field simulation.
     #:padding-wavelengths 0.5))
  (define result
    (simulate
     engine openems
     sweep '(900 1100)
     profile report-fixture
     progress #f
     record-radiation #f
     record-fields
     (field-capture
      #:frequency 1000
      #:excitation 'input
      #:current 'conductors
      #:volume '(electric magnetic)
      #:max-samples 800000)
     keep-artifacts #t))
  (define report
    (write-html-report result "scratch/html-report-m4-matched-microstrip.html"))
  (printf "Portable report: ~a\n" report))
