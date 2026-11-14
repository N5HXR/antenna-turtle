#lang racket/base

(require rackunit
         "../antenna-turtle/private/rf-phase-clock.rkt")

(test-case "RF phase advances and wraps"
  (check-= (advance-rf-phase 0 1 1) 180 1e-12)
  (check-= (advance-rf-phase 350 0.1 1) 8 1e-12)
  (check-= (advance-rf-phase 10 1 2) 10 1e-12))

(test-case "pause and restart do not accumulate hidden elapsed time"
  (define clock (make-rf-phase-clock #:now 1000.0))
  (check-= (rf-phase-clock-tick! clock 1500.0) 90.0 1e-12)
  (rf-phase-clock-stop! clock)
  (check-= (rf-phase-clock-tick! clock 9000.0) 90.0 1e-12)
  (rf-phase-clock-start! clock 20000.0)
  (check-= (rf-phase-clock-tick! clock 20500.0) 180.0 1e-12))

(test-case "manual phase and speed settings are retained"
  (define clock (make-rf-phase-clock #:running? #f #:now 0.0))
  (rf-phase-clock-set-phase! clock 725.0)
  (rf-phase-clock-set-speed! clock 0.5)
  (check-= (rf-phase-clock-phase clock) 5.0 1e-12)
  (check-= (rf-phase-clock-speed clock) 0.5 1e-12)
  (rf-phase-clock-start! clock 100.0)
  (check-= (rf-phase-clock-tick! clock 1100.0) 95.0 1e-12))

(test-case "RF phase clock validates inputs"
  (check-exn exn:fail:contract?
             (lambda () (advance-rf-phase 0 -1 1)))
  (check-exn exn:fail:contract?
             (lambda () (advance-rf-phase 0 1 0)))
  (check-exn exn:fail:contract?
             (lambda () (make-rf-phase-clock #:running? 'yes))))
