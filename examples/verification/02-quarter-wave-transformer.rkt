#lang antenna-turtle

(require "common.rkt")

;; A nominal 70.7-ohm quarter-wave section transforms a 100-ohm load to
;; approximately 50 ohms at 1 GHz. Width and length are initial FR4 estimates.
(model title "Verification 02: quarter-wave transformer"
       frequency 1000 impedance 50)

(define substrate (dielectric name lossless-fr4 er 4.4))
(define substrate-height 1.6)
(define transformer-width 1.6)
(define transformer-length 42.5)

(with-scale millimeters
  (with-material substrate
    (cuboid size '(85 45 1.6) anchor bottom))
  (with-material copper
    (sheet rect size '(85 45))
    (move back (half transformer-length) up substrate-height)
    (port up name input gap substrate-height size transformer-width anchor end)
    (with-traces transformer-width (move forward transformer-length))
    (lumped-element up name load resistance {100 * ohms}
                    gap substrate-height size transformer-width anchor end)))

(module+ main
  (show-solid-model)
  (define result
    (simulate engine openems sweep '(700 1300) profile standard
              keep-artifacts #t))
  (report-near "transformed input impedance at 1 GHz"
               (impedance-at result 1000 #:port 'input #:interpolate? #t)
               50 #:relative 0.15)
  (report-at-most "transformer S11 at 1 GHz (dB)"
                  (s11-db-at result 1000 #:port 'input #:interpolate? #t)
                  -12)
  (show-smith-chart result)
  (show-return-loss-sweep result))
