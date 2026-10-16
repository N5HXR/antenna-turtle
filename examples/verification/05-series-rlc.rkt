#lang antenna-turtle

(require "common.rkt")

;; A two-port series RLC fixture with f0 = 1/(2*pi*sqrt(L*C)) ~= 1 GHz.
(model title "Verification 05: series RLC fixture"
       frequency 1000 impedance 50)

(define substrate (dielectric name lossless-fr4 er 4.4))
(define substrate-height 1.6)
(define trace-width 3.1)
(define component-gap 1)

(with-scale millimeters
  (with-material substrate
    (cuboid size '(70 40 1.6) anchor bottom))
  (with-material copper
    (sheet rect size '(70 40))
    (move back 25 up substrate-height)
    (port up name input gap substrate-height size trace-width anchor end)
    (with-traces trace-width (move forward 24.5))
    (move forward 0.5)
    (lumped-element forward name resonator
                    resistance {5 * ohms}
                    inductance {10 * nanohenries}
                    capacitance {2.533 * picofarads}
                    topology series
                    gap component-gap size (list trace-width 0.2))
    (move forward 0.5)
    (with-traces trace-width (move forward 24.5))
    (port up name output gap substrate-height size trace-width anchor end)))

(module+ main
  (show-solid-model)
  (define result
    (simulate engine openems sweep '(600 1400) profile standard
              keep-artifacts #t))
  (report-near "series-RLC insertion at resonance (dB)"
               (s-parameter-db-at result 1000 #:from 'input #:to 'output
                                  #:interpolate? #t)
               (* 20 (/ (log (/ 100 105)) (log 10))) #:absolute 1.5)
  (report-reciprocity result 1000 s-parameter-at)
  (show-s-parameter-magnitude result)
  (show-s-parameter-phase result))
