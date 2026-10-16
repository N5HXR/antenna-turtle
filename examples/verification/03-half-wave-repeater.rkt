#lang antenna-turtle

(require "common.rkt")

;; A guided half-wave line repeats its terminating impedance. The provisional
;; 82 mm length is based on the effective permittivity of this 50-ohm line.
(model title "Verification 03: half-wave impedance repeater"
       frequency 1000 impedance 50)

(define substrate (dielectric name lossless-fr4 er 4.4))
(define substrate-height 1.6)
(define trace-width 3.1)
(define line-length 82)
(define load-resistance 75)

(with-scale millimeters
  (with-material substrate
    (cuboid size '(125 50 1.6) anchor bottom))
  (with-material copper
    (sheet rect size '(125 50))
    (move back (half line-length) up substrate-height)
    (port up name input gap substrate-height size trace-width anchor end)
    (with-traces trace-width (move forward line-length))
    (lumped-element up name load resistance load-resistance
                    gap substrate-height size trace-width anchor end)))

(module+ main
  (show-solid-model)
  (define result
    (simulate engine openems sweep '(750 1250) profile standard
              keep-artifacts #t))
  (report-near "repeated 75-ohm load at 1 GHz"
               (impedance-at result 1000 #:port 'input #:interpolate? #t)
               load-resistance #:relative 0.15)
  (report-near "expected 75-ohm-load S11 (dB)"
               (s11-db-at result 1000 #:port 'input #:interpolate? #t)
               (* 20 (/ (log 0.2) (log 10))) #:absolute 2.0)
  (show-impedance-sweep result)
  (show-smith-chart result))
