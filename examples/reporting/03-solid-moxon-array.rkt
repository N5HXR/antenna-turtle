#lang antenna-turtle

;; Milestone 3 array fixture: a Cebik Moxon scaled from 29 MHz to 1 GHz.  The
;; ordinary Turtle wires exercise the OpenEMS capsule-solid export and
;; triangulated surface-current/charge reconstruction, while the large field
;; volume exposes the directional interaction between driven and parasitic
;; elements.
(define (build-model)
  (model title "HTML report fixture: solid Moxon array"
         frequency 1000 impedance 50
         max-length {wavelength / 60}
         wire-diameter {wavelength / 120})

  ;; Dimensions from L. B. Cebik, W4RNL:
  ;; https://antenna2.github.io/cebik/content/moxon/moxpage.html
  (define frequency-scale (/ 29.0 1000))
  (define a (* 147.96 inch frequency-scale))
  (define b (* 22.09 inch frequency-scale))
  (define c (* 4.28 inch frequency-scale))
  (define d (* 27.71 inch frequency-scale))
  (define wire-radius (/ (current-wire-diameter) 2))

  (define (element short long driven?)
    (with-wire
      (move forward short)
      (when driven? (feed center))
      (move left long)
      (move back short)))

  (element (- b wire-radius) a #t)
  (move back (+ wire-radius wire-radius c))
  (turn left 180)
  (element (- d wire-radius) a #f))

(build-model)

(module+ main
  (reset-model!)
  (build-model)
  (define report-fixture
    (derive-simulation-profile
     standard #:name 'solid-moxon-report-fixture
     #:frequency-steps 61
     #:maximum-timesteps 80000 #:end-criteria 1e-3
     #:cells-per-wavelength 50
     #:minimum-dielectric-cells 10
     #:minimum-trace-cells 9
     #:wire-segments 20
     ;; A deliberately large domain lets the animated slices show the coupled
     ;; near field transitioning into the array's directional radiation.
     #:padding-wavelengths 1.5))
  (define result
    (simulate
     engine openems
     sweep '(850 1150)
     profile report-fixture
     progress #t
     record-radiation #f
     record-fields
     (field-capture #:frequency 1000
                    #:current 'conductors
                    #:volume '(electric magnetic)
                    #:max-samples 800000)
     keep-artifacts #t))
  (define report
    (write-html-report result "scratch/html-report-m3-solid-moxon-array.html"))
  (printf "Portable report: ~a\n" report))
