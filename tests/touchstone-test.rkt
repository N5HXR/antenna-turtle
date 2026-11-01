#lang racket

(require rackunit
         racket/string
         "../antenna-turtle/main.rkt"
         "../antenna-turtle/private/network.rkt")

(define fixture
  (network-sweep
   'fixture #f 50
   (list (network-sample "feedpoint" 3.5 0 75 0 1)
         (network-sample "feedpoint" 3.6 0 25 0 3))))

(test-case "write-s1p defaults its reference to the model impedance"
  (reset-model!)
  (model impedance 75)
  (define output (open-output-string))
  (write-s1p output fixture)
  (define text (get-output-string output))
  (check-true (string-contains? text "# MHz S RI R 75.0"))
  (check-true (string-contains? text "3.5 0.0 0.0"))
  (check-true (string-contains? text "3.6 -0.5 0.0")))

(test-case "write-s1p permits an explicit reference-impedance override"
  (define output (open-output-string))
  (write-s1p output fixture #:reference-impedance 50)
  (define text (get-output-string output))
  (check-true (string-contains? text "# MHz S RI R 50.0"))
  (check-true (string-contains? text "3.5 0.2 0.0")))
