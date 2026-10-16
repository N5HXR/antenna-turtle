#lang antenna-turtle

(require "common.rkt")

;; A capacitively coupled open-open microstrip resonator. Its physical length
;; is an initial guided-half-wave estimate; the measured pass peak is the item
;; to tune and then use as the regression observation.
(model title "Verification 08: half-wave resonator"
       frequency 1000 impedance 50)

(define substrate (dielectric name lossless-fr4 er 4.4))
(define substrate-height 1.6)
(define trace-width 3.1)
(define resonator-length 82)
(define feed-length 10)
(define coupling-gap 1)
(define coupling-capacitance {0.2 * picofarads})

(define (trace-from start length)
  (from-here
    (move forward start)
    (with-traces trace-width (move forward length))))

(with-scale millimeters
  (with-material substrate
    (cuboid size '(130 45 1.6) anchor bottom))
  (with-material copper
    (sheet rect size '(130 45))
    (move up substrate-height)
    (define resonator-half (half resonator-length))
    (define left-feed-start
      (- (+ resonator-half coupling-gap feed-length)))
    (define right-feed-start (+ resonator-half coupling-gap))
    (trace-from (- resonator-half) resonator-length)
    (trace-from left-feed-start feed-length)
    (trace-from right-feed-start feed-length)
    (from-here
      (move forward (+ (- resonator-half) (- (half coupling-gap))))
      (lumped-element forward name input-coupling
                      capacitance coupling-capacitance gap coupling-gap
                      size (list trace-width 0.2)))
    (from-here
      (move forward (+ resonator-half (half coupling-gap)))
      (lumped-element forward name output-coupling
                      capacitance coupling-capacitance gap coupling-gap
                      size (list trace-width 0.2)))
    (from-here
      (move forward left-feed-start)
      (port up name input gap substrate-height size trace-width anchor end))
    (from-here
      (move forward (+ right-feed-start feed-length))
      (port up name output gap substrate-height size trace-width anchor end))))

(module+ main
  (show-solid-model)
  (define result
    (simulate engine openems sweep '(650 1350) profile standard
              keep-artifacts #t))
  (define peak-frequency
    (frequency-of-maximum
     result (measurement-frequencies result)
     (lambda (sweep frequency)
       (s-parameter-db-at sweep frequency #:from 'input #:to 'output))))
  (report-near "half-wave transmission peak (MHz)"
               peak-frequency 1000 #:relative 0.15)
  (report-reciprocity result peak-frequency s-parameter-at)
  (show-s-parameter-magnitude result))
