#lang antenna-turtle

(require "common.rkt")

;; A 40 mm nominal 50-ohm microstrip. This is the first port, material, mesh,
;; and S-parameter smoke test; tighten the tolerances after convergence runs.
(model title "Verification 00: matched microstrip" frequency 1000 impedance 50)

(define substrate (dielectric name lossless-fr4 er 4.4))
(define substrate-height 1.6)
(define trace-width 3.1)
(define line-length 40)

(with-scale millimeters
  (with-material substrate
    (cuboid size '(80 50 1.6) anchor bottom))
  (with-material copper
    (sheet rect size '(80 50))
    (move back (half line-length) up substrate-height)
    (port up name input gap substrate-height size trace-width anchor end)
    (with-traces trace-width (move forward line-length))
    (port up name output gap substrate-height size trace-width anchor end)))

(module+ main
  (show-solid-model)
  (define result
    (simulate engine openems sweep '(900 1100) profile standard
              keep-artifacts #t))
  (report-near "characteristic impedance at 1 GHz"
               (characteristic-impedance-at result 1000) 50
               #:relative 0.08)
  (report-at-most "input S11 at 1 GHz (dB)"
                  (s-parameter-db-at result 1000 #:from 'input #:to 'input
                                     #:interpolate? #t)
                  -15)
  (report-near "insertion at 1 GHz (dB)"
               (s-parameter-db-at result 1000 #:from 'input #:to 'output
                                  #:interpolate? #t)
               0 #:absolute 1.0)
  (report-reciprocity result 1000 s-parameter-at)
  (show-s-parameter-magnitude result)
  (show-smith-chart result))
