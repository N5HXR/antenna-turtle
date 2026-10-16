#lang antenna-turtle

(require (prefix-in m: manifold))

;; Milestone 3 fixture: a genuinely triangulated PEC dipole. Unlike the
;; zero-thickness sheet fixture, its surface current and charge are rebuilt
;; from H and D samples on a Yee-aligned shell around each cylindrical arm.
(define (build-model)
  (model title "HTML report fixture: solid cylindrical dipole"
         frequency 1000 impedance 73
         max-length {wavelength / 55})
  (define gap 0.001)
  (define radius 0.002)
  (define total-length (* 0.95 (/ (model-wavelength) 2)))
  (define arm-length (/ (- total-length gap) 2))
  (define (cylinder-at-z start)
    (define primitive (m:cylinder arm-length radius #:segments 32))
    (define placed (m:translate primitive `(0 0 ,start)))
    (m:solid-close! primitive)
    placed)
  (define lower (cylinder-at-z (- (+ (/ gap 2) arm-length))))
  (define upper (cylinder-at-z (/ gap 2)))
  (body name lower-arm material pec geometry lower priority 20)
  (body name upper-arm material pec geometry upper priority 20)
  (port up name feed-1 impedance 73 gap gap width (* 2 radius)
        depth (* 2 radius))
  (m:solid-close! lower)
  (m:solid-close! upper))

(build-model)

(module+ main
  (reset-model!)
  (build-model)
  (define report-fixture
    (derive-simulation-profile
     standard #:name 'solid-report-fixture #:frequency-steps 61
     #:maximum-timesteps 60000 #:end-criteria 1e-3
     #:padding-wavelengths 0.75))
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
    (write-html-report result "scratch/html-report-m3-solid-dipole.html"))
  (printf "Portable report: ~a\n" report))
