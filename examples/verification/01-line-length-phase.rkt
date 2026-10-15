#lang antenna-turtle

(require "common.rkt")

;; Port discontinuities should cancel when otherwise identical line lengths
;; are compared. The extra 20 mm should add the predicted guided phase while
;; leaving characteristic impedance nearly unchanged.
(define center-frequency 1000)
(define substrate-height 1.6)
(define trace-width 3.1)
(define substrate (dielectric name lossless-fr4 er 4.4))

(define (build-line length)
  (reset-model!)
  (model title (format "Verification 01: ~a mm line" length)
         frequency center-frequency impedance 50)
  (with-scale millimeters
    (with-material substrate
      (cuboid size (list (+ length 40) 50 substrate-height) anchor bottom))
    (with-material copper
      (sheet rect size (list (+ length 40) 50))
      (move back (half length) up substrate-height)
      (port up name input gap substrate-height size trace-width anchor end)
      (with-traces trace-width (move forward length))
      (port up name output gap substrate-height size trace-width anchor end))))

(define (run-line length)
  (build-line length)
  (simulate engine openems sweep '(900 1100) profile standard
            keep-artifacts #t))

(module+ main
  (define short-result (run-line 20))
  (define long-result (run-line 40))
  (define short-phase
    (s-parameter-phase-at short-result center-frequency
                          #:from 'input #:to 'output #:interpolate? #t))
  (define long-phase
    (s-parameter-phase-at long-result center-frequency
                          #:from 'input #:to 'output #:interpolate? #t))
  ;; Hammerstad-style first estimate for this geometry: epsilon-effective is
  ;; about 3.33, giving roughly -43.8 degrees for the additional 20 mm.
  (report-near "phase added by 20 mm"
               (principal-degree-difference long-phase short-phase)
               -43.8 #:absolute 6)
  (report-near "20/40 mm characteristic-impedance agreement"
               (characteristic-impedance-at short-result center-frequency)
               (characteristic-impedance-at long-result center-frequency)
               #:relative 0.03)
  (show-s-parameter-phase long-result))
