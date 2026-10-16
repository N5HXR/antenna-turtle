#lang antenna-turtle

(require "common.rkt")

;; Run identical 80 mm lines with ideal and realistic materials. The lossy
;; result should have lower transmission, and its budget should expose where
;; the accepted power went.
(define center-frequency 1000)
(define substrate-height 1.6)
(define trace-width 3.1)
(define line-length 80)
(define lossless-fr4 (dielectric name lossless-fr4 er 4.4))

(define (build-line dielectric-material conductor-material title)
  (reset-model!)
  (model title title frequency center-frequency impedance 50)
  (with-scale millimeters
    (with-material dielectric-material
      (cuboid size '(125 50 1.6) anchor bottom))
    (with-material conductor-material
      (sheet rect size '(125 50))
      (move back (half line-length) up substrate-height)
      (port up name input gap substrate-height size trace-width anchor end)
      (with-traces trace-width (move forward line-length))
      (port up name output gap substrate-height size trace-width anchor end))))

(define (run-line dielectric-material conductor-material title)
  (build-line dielectric-material conductor-material title)
  (simulate engine openems sweep '(800 1200) profile standard
            keep-artifacts #t))

(module+ main
  (define ideal-result (run-line lossless-fr4 pec "Ideal line"))
  (define lossy-result (run-line fr4 copper "Lossy FR4/copper line"))
  (define ideal-s21
    (s-parameter-db-at ideal-result center-frequency
                       #:from 'input #:to 'output #:interpolate? #t))
  (define lossy-s21
    (s-parameter-db-at lossy-result center-frequency
                       #:from 'input #:to 'output #:interpolate? #t))
  (report-true "lossy line has more insertion loss"
               (< lossy-s21 ideal-s21)
               (format "ideal ~a dB; lossy ~a dB" ideal-s21 lossy-s21))
  (report-reciprocity lossy-result center-frequency s-parameter-at)
  (display-power-budget
   (power-budget lossy-result #:excitation 'input
                 #:frequency center-frequency))
  (show-s-parameter-magnitude lossy-result))
