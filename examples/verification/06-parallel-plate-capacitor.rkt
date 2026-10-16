#lang antenna-turtle

(require "common.rkt")

;; A PTFE-filled parallel-plate capacitor. The first-order target ignores edge
;; fringing: C = epsilon0 * epsilon-r * area / separation.
(model title "Verification 06: parallel-plate capacitor"
       frequency 1000 impedance 50)

(define plate-size 20)
(define separation 1.6)
(define expected-capacitance
  (* 8.8541878128e-12 2.1
     (/ (sqr (* plate-size millimeters)) (* separation millimeters))))

(with-scale millimeters
  (with-material ptfe
    (cuboid size (list plate-size plate-size separation) anchor bottom))
  (with-material copper
    (sheet rect name lower-plate size (list plate-size plate-size))
    (move up separation)
    (sheet rect name upper-plate size (list plate-size plate-size))
    (move down separation)
    (port up name input gap separation size 3 anchor start)))

(module+ main
  (show-solid-model)
  (define result
    (simulate engine openems sweep '(700 1300) profile standard
              keep-artifacts #t))
  (define admittance
    (admittance-at result 1000 #:port 'input #:interpolate? #t))
  (define measured-capacitance
    (/ (imag-part admittance) (* 2 pi 1e9)))
  (report-near "parallel-plate capacitance"
               measured-capacitance expected-capacitance
               #:relative 0.20)
  (printf "Analytic no-fringing target: ~a pF\n"
          (/ expected-capacitance picofarads))
  (show-impedance-sweep result)
  (show-smith-chart result))
