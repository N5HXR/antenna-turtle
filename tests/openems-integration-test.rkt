#lang racket

(require rackunit
         "../antenna-turtle/main.rkt")

;; Deliberately opt-in: even this small reference normally takes minutes.
;; Run with:
;;   ANTENNA_TURTLE_OPENEMS_INTEGRATION=1 \
;;     raco test tests/openems-integration-test.rkt
(when (getenv "ANTENNA_TURTLE_OPENEMS_INTEGRATION")
  (test-case "one wire dipole runs through NEC2C and OpenEMS end to end"
    (reset-model!)
    (model title "OpenEMS integration dipole"
           frequency 915
           impedance 50
           wire-diameter (/ wavelength 100))
    (with-wire
      (spread up (* 0.47 wavelength) feed center))

    (define nec-pattern
      (nec2c-radiation-grid #:theta-step 30 #:phi-step 30))
    (define nec-peak
      (apply max
             (filter real?
                     (map nec2c-pattern-sample-total-gain-db
                          (nec2c-pattern-grid-samples nec-pattern)))))

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
    ;; This tolerance catches units, transform, feed, or pattern-normalization
    ;; failures without pretending MoM wires and gridded finite solids agree
    ;; more closely than their numerical models warrant.
    (check-true (< (abs (- peak nec-peak)) 1.5))
    (define conversion
      (hash-ref (openems-run-info-manifest
                 (openems-sweep-result-run result))
                'wire_conversion))
    (check-equal? (hash-ref conversion 'representation) "capsule-union")
    (check-equal? (hash-ref conversion 'edge_count) 1)
    (openems-close! result)
    (clear-wires)))
