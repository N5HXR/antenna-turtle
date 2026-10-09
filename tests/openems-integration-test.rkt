#lang racket

(require rackunit
         (prefix-in m: manifold)
         "../antenna-turtle/main.rkt")

;; Deliberately opt-in: even this small reference normally takes minutes.
;; Run with:
;;   ANTENNA_TURTLE_OPENEMS_INTEGRATION=1 \
;;     raco test tests/openems-integration-test.rkt
(when (getenv "ANTENNA_TURTLE_OPENEMS_INTEGRATION")
  (test-case "OpenEMS executes a finite-port PEC dipole end to end"
    (reset-model!)
    (model title "OpenEMS integration dipole"
           frequency 915
           impedance 50)
    (define gap (max (/ wavelength 1000) (/ (current-wire-diameter) 2)))
    (define radius (/ wavelength 200))
    (define arm-length (/ (- (* 0.47 wavelength) gap) 2))
    (define lower-source (m:cylinder arm-length radius #:segments 32))
    (define upper-source (m:cylinder arm-length radius #:segments 32))
    (define lower
      (m:translate lower-source `(0 0 ,(- (+ (/ gap 2) arm-length)))))
    (define upper (m:translate upper-source `(0 0 ,(/ gap 2))))
    (body lower material pec geometry lower priority 20)
    (body upper material pec geometry upper priority 20)
    (port up name "feed" impedance 50 gap gap width gap depth gap)
    (for-each m:solid-close!
              (list lower-source upper-source lower upper))

    (define result
      (openems-sweep 750 1050
                     #:steps 31
                     #:cells-per-wavelength 15
                     #:max-timesteps 50000
                     #:end-criteria 1e-4
                     #:keep-artifacts? #t))
    (define samples (openems-sweep-result-samples result))
    (check-equal? (length samples) 31)
    (check-true
     (andmap (lambda (sample)
               (and (real? (openems-port-sample-s11-db sample))
                    (number? (openems-port-sample-impedance sample))))
             samples))
    ;; This is a smoke test, not a demand that FDTD reproduce NEC2C.
    (check-true (< (apply min (map openems-port-sample-s11-db samples)) -6))
    (define pattern
      (openems-radiation-grid result
                              #:frequency 915
                              #:theta-step 30
                              #:phi-step 30))
    (check-equal? (length (nec2c-pattern-grid-samples pattern)) 84)
    (define peak
      (apply max
             (filter real?
                     (map nec2c-pattern-sample-total-gain-db
                          (nec2c-pattern-grid-samples pattern)))))
    (check-true (< 0 peak 4))
    (openems-close! result)
    (clear-bodies)))
