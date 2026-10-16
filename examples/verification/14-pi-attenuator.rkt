#lang antenna-turtle

(require "common.rkt")

;; A symmetric 6 dB, 50-ohm resistor pi attenuator. For K=10^(A/20):
;; Rseries = Z0*(K^2-1)/(2K), Rshunt = Z0*(K+1)/(K-1).
(model title "Verification 14: lumped resistor pi attenuator"
       frequency 1000 impedance 50)

(define attenuation-db 6)
(define z0 50)
(define k (expt 10 (/ attenuation-db 20)))
(define series-resistance (* z0 (/ (- (sqr k) 1) (* 2 k))))
(define shunt-resistance (* z0 (/ (+ k 1) (- k 1))))
(define substrate (dielectric name lossless-fr4 er 4.4))
(define substrate-height 1.6)
(define trace-width 3.1)

(with-scale millimeters
  (with-material substrate
    (cuboid size '(70 40 1.6) anchor bottom))
  (with-material copper
    (sheet rect size '(70 40))
    (move back 15 up substrate-height)
    (port up name input gap substrate-height size trace-width anchor end)
    (from-here
      (move forward 10)
      (lumped-element up name input-shunt resistance shunt-resistance
                      gap substrate-height size trace-width anchor end))
    (with-traces trace-width (move forward 14.5))
    (move forward (half substrate-height) up (half substrate-height))
    (lumped-element forward name series-arm resistance series-resistance
                    gap substrate-height size (list trace-width substrate-height))
    (move forward (half substrate-height) down (half substrate-height))
    (with-traces trace-width (move forward 14.5))
    (from-here
      (move back 10)
      (lumped-element up name output-shunt resistance shunt-resistance
                      gap substrate-height size trace-width anchor end))
    (port up name output gap substrate-height size trace-width anchor end)))

(module+ main
  (show-solid-model)
  (printf "Designed resistor values: series ~a ohms; each shunt ~a ohms\n"
          series-resistance shunt-resistance)
  (define result
    (simulate engine openems sweep '(700 1300) profile standard
              keep-artifacts #t))
  (report-near "pi-attenuator S21 at 1 GHz (dB)"
               (s-parameter-db-at result 1000 #:from 'input #:to 'output
                                  #:interpolate? #t)
               (- attenuation-db) #:absolute 0.75)
  (report-at-most "pi-attenuator input S11 at 1 GHz (dB)"
                  (s-parameter-db-at result 1000 #:from 'input #:to 'input
                                     #:interpolate? #t)
                  -18)
  (report-reciprocity result 1000 s-parameter-at)
  (show-s-parameter-magnitude result)
  (show-smith-chart result))
