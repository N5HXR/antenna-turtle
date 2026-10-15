#lang antenna-turtle

(require "common.rkt")

;; A one-port 50-ohm dummy load. Accepted power should overwhelmingly become
;; lumped-resistor heat rather than radiation or dielectric loss.
(model title "Verification 04: lumped 50-ohm load"
       frequency 1000 impedance 50)

(define substrate (dielectric name lossless-fr4 er 4.4))
(define substrate-height 1.6)
(define trace-width 3.1)
(define trace-length 35)

(with-scale millimeters
  (with-material substrate
    (cuboid size '(65 35 1.6) anchor bottom))
  (with-material copper
    (sheet rect size '(65 35))
    (move back (half trace-length) up substrate-height)
    (port up name input gap substrate-height size trace-width anchor end)
    (with-traces trace-width (move forward trace-length))
    (lumped-element up name termination resistance {50 * ohms}
                    gap substrate-height size trace-width anchor end)))

(module+ main
  (show-solid-model)
  (define result
    (simulate engine openems sweep '(800 1200) profile standard
              keep-artifacts #t))
  (report-near "dummy-load impedance at 1 GHz"
               (impedance-at result 1000 #:port 'input #:interpolate? #t)
               50 #:relative 0.10)
  (report-at-most "dummy-load S11 at 1 GHz (dB)"
                  (s11-db-at result 1000 #:port 'input #:interpolate? #t)
                  -15)
  (display-power-budget (power-budget result #:frequency 1000))
  (show-smith-chart result))
