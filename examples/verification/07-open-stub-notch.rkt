#lang antenna-turtle

(require "common.rkt")

;; An open shunt stub approximately one guided quarter-wave long transforms to
;; a short at its junction and should create a transmission notch near 1 GHz.
(model title "Verification 07: open-stub notch"
       frequency 1000 impedance 50)

(define substrate (dielectric name lossless-fr4 er 4.4))
(define substrate-height 1.6)
(define trace-width 3.1)
(define through-length 80)
(define stub-length 41)

(with-scale millimeters
  (with-material substrate
    (cuboid size '(125 100 1.6) anchor bottom))
  (with-material copper
    (sheet rect size '(125 100))
    (move back (half through-length) up substrate-height)
    (port up name input gap substrate-height size trace-width anchor end)
    (with-traces trace-width (move forward through-length))
    (port up name output gap substrate-height size trace-width anchor end)
    (from-here
      (move back (half through-length))
      (turn left 90)
      (with-traces trace-width (move forward stub-length)))))

(module+ main
  (show-solid-model)
  (define result
    (simulate engine openems sweep '(600 1400) profile standard
              keep-artifacts #t))
  (report-at-most "quarter-wave stub S21 at 1 GHz (dB)"
                  (s-parameter-db-at result 1000 #:from 'input #:to 'output
                                     #:interpolate? #t)
                  -10)
  (report-reciprocity result 1000 s-parameter-at)
  (show-s-parameter-magnitude result))
