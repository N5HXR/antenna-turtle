#lang antenna-turtle

(require "common.rkt")

;; A square ring weakly coupled across a one-millimeter edge gap to a through
;; line. The ring circumference is approximately one guided wavelength.
(model title "Verification 09: edge-coupled ring resonator"
       frequency 1000 impedance 50)

(define substrate (model-dielectric fr4)) ;(dielectric name lossless-fr4 er 4.4))
(define substrate-height 1.6)
(define trace-width 3.1)
(define ring-side 41)
(define feed-offset (+ (half ring-side) trace-width 1))

(with-scale millimeters
  (with-material substrate
    (cuboid size '(110 90 1.6) anchor bottom))
  (with-material copper
    (sheet rect size '(110 90))
    (move up substrate-height)
    ;; Through line, one millimeter clear of the ring's lower edge.
    (from-here
      (move back 40 right feed-offset)
      (port up name input gap substrate-height size trace-width anchor end)
      (with-traces trace-width (move forward 80))
      (port up name output gap substrate-height size trace-width anchor end))
    ;; Closed square ring.
    (from-here
      (move back (half ring-side) right (half ring-side))
      (with-traces trace-width
        (move forward ring-side)
        (turn left 90)
        (move forward ring-side)
        (turn left 90)
        (move forward ring-side)
        (turn left 90)
        (move forward ring-side)))))

(module+ main
  (show-solid-model)
  (define result
    (simulate engine openems sweep '(650 1350) profile standard
              keep-artifacts #t
              record-radiation #f))
  (define notch-frequency
    (frequency-of-minimum
     result (measurement-frequencies result)
     (lambda (sweep frequency)
       (s-parameter-db-at sweep frequency #:from 'input #:to 'output))))
  (report-near "ring transmission notch (MHz)"
               notch-frequency 1000 #:relative 0.20)
  (report-at-most "ring-notch depth (dB)"
                  (s-parameter-db-at result notch-frequency
                                     #:from 'input #:to 'output)
                  -3)
  (report-reciprocity result notch-frequency s-parameter-at)
  (show-s-parameter-magnitude result))
