#lang racket

(require rackunit
         (prefix-in m: manifold)
         "../antenna-turtle/main.rkt")

;; Deliberately opt-in. This is a short solver/API smoke test, not an
;; electrically converged transmission-line benchmark:
;;   ANTENNA_TURTLE_OPENEMS_MULTIPORT_INTEGRATION=1 \
;;     raco test tests/openems-multiport-integration-test.rkt
(when (getenv "ANTENNA_TURTLE_OPENEMS_MULTIPORT_INTEGRATION")
  (test-case "two lumped ports produce a complete S matrix"
    (reset-model!)
    (model title "OpenEMS multiport integration smoke test"
           frequency 1000
           impedance 50)

    (define board-length 0.030)
    (define width 0.012)
    (define height 0.002)
    (define trace-width 0.003)
    (define substrate
      (m:cube board-length width height #:center? #t))
    (body name substrate
          geometry substrate
          material (dielectric #:name 'substrate
                               #:relative-permittivity 2.2)
          priority 10)
    (sheet name ground
           points `((,(- (/ board-length 2)) ,(- (/ width 2)))
                    (,(+ (/ board-length 2)) ,(- (/ width 2)))
                    (,(+ (/ board-length 2)) ,(+ (/ width 2)))
                    (,(- (/ board-length 2)) ,(+ (/ width 2))))
           material pec priority 20)
    (move up height)
    (sheet name trace
           points `((,(- (/ board-length 2)) ,(- (/ trace-width 2)))
                    (,(+ (/ board-length 2)) ,(- (/ trace-width 2)))
                    (,(+ (/ board-length 2)) ,(+ (/ trace-width 2)))
                    (,(- (/ board-length 2)) ,(+ (/ trace-width 2))))
           material pec priority 20)
    (move down (/ height 2))
    (from-here
      (move back 0.010)
      (port up name 'input impedance 50
            gap height width trace-width depth 0.002))
    (from-here
      (move forward 0.010)
      (port up name 'output impedance 50
            gap height width trace-width depth 0.002))
    (m:solid-close! substrate)

    (define result
      (openems-sweep 800 1200
                     #:steps 9
                     #:cells-per-wavelength 8
                     #:padding-wavelengths 0.08
                     #:max-timesteps 400
                     #:end-criteria 1e-2
                     #:progress? #f
                     #:keep-artifacts? #t))
    (check-true (openems-multiport-result? result))
    (check-equal? (length (openems-multiport-result-ports result)) 2)
    (check-equal? (length (openems-multiport-result-s-parameters result))
                  (* 9 2 2))
    (check-equal?
     (remove-duplicates
      (map openems-s-parameter-sample-output-port
           (openems-multiport-result-s-parameters result)))
     '(input output))
    (openems-close! result)
    (clear-bodies)))
