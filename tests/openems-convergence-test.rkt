#lang racket

(require rackunit
         "../antenna-turtle/main.rkt")

;; Deliberately separate from the normal integration switch: three FDTD runs
;; can take well over an hour on a modest workstation.
;;
;;   ANTENNA_TURTLE_OPENEMS_CONVERGENCE=1 \
;;     raco test tests/openems-convergence-test.rkt

(struct convergence-sample
  (cells-per-wavelength best-frequency impedance s11-db peak-directivity)
  #:transparent)

(define (finite-number? value)
  (and (number? value)
       (rational? (real-part value))
       (rational? (imag-part value))))

(define (run-resolution cells-per-wavelength)
  (define result
    (openems-sweep 800 1050
                   #:steps 51
                   #:cells-per-wavelength cells-per-wavelength
                   #:max-timesteps 75000
                   #:end-criteria 1e-5
                   #:progress? #t
                   #:keep-artifacts? #t))
  (dynamic-wind
    void
    (lambda ()
      (define best
        (argmin (lambda (sample)
                  (magnitude
                   (openems-port-sample-reflection-coefficient sample)))
                (openems-sweep-result-samples result)))
      (define pattern
        (openems-radiation-grid result
                                #:frequency
                                (openems-port-sample-frequency-mhz best)
                                #:theta-step 15
                                #:phi-step 15))
      (define peak
        (apply max
               (filter real?
                       (map nec2c-pattern-sample-total-gain-db
                            (nec2c-pattern-grid-samples pattern)))))
      (convergence-sample
       cells-per-wavelength
       (openems-port-sample-frequency-mhz best)
       (openems-port-sample-impedance best)
       (openems-port-sample-s11-db best)
       peak))
    (lambda () (openems-close! result))))

(define (distance selector first second)
  (magnitude (- (selector first) (selector second))))

(define (check-converging selector coarse medium fine floor label)
  (define coarse-step (distance selector coarse medium))
  (define fine-step (distance selector medium fine))
  (check-true
   (<= fine-step (+ (* 1.5 coarse-step) floor))
   (format "~a diverged under refinement: coarse/medium ~a, medium/fine ~a"
           label coarse-step fine-step)))

(when (getenv "ANTENNA_TURTLE_OPENEMS_CONVERGENCE")
  (test-case "wire dipole remains stable under basic Yee-mesh refinement"
    (reset-model!)
    (model title "OpenEMS wire-dipole convergence"
           frequency 915
           impedance 50
           wire-diameter (/ wavelength 100))
    (with-wire
      (spread up (* 0.47 wavelength) feed center))

    (define samples (map run-resolution '(10 15 20)))
    (for ([sample (in-list samples)])
      (printf "OpenEMS convergence ~a cells/lambda: ~s\n"
              (convergence-sample-cells-per-wavelength sample)
              sample)
      (check-true (finite-number? (convergence-sample-best-frequency sample)))
      (check-true (finite-number? (convergence-sample-impedance sample)))
      (check-true (finite-number? (convergence-sample-s11-db sample)))
      (check-true (finite-number? (convergence-sample-peak-directivity sample))))

    (define coarse (first samples))
    (define medium (second samples))
    (define fine (third samples))
    ;; Floors acknowledge the 5 MHz sweep sampling and normal gridded-solver
    ;; noise. The relative term detects a result that worsens dramatically as
    ;; the mesh is refined without demanding monotonic numerical behavior.
    (check-converging convergence-sample-best-frequency
                      coarse medium fine 5 "best-match frequency (MHz)")
    (check-converging convergence-sample-impedance
                      coarse medium fine 5 "best-match impedance (ohms)")
    (check-converging convergence-sample-s11-db
                      coarse medium fine 2 "best-match S11 (dB)")
    (check-converging convergence-sample-peak-directivity
                      coarse medium fine 0.25 "peak directivity (dBi)")
    (clear-wires)))
