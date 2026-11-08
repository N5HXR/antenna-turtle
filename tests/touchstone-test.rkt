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
  (check-true (string-contains? text "# MHz S RI R 75.000000000000"))
  (check-true
   (string-contains? text
                     "3.500000000000 0.000000000000 0.000000000000"))
  (check-true
   (string-contains? text
                     "3.600000000000 -0.500000000000 0.000000000000")))

(test-case "write-s1p permits an explicit reference-impedance override"
  (define output (open-output-string))
  (write-s1p output fixture #:reference-impedance 50)
  (define text (get-output-string output))
  (check-true (string-contains? text "# MHz S RI R 50.000000000000"))
  (check-true
   (string-contains? text
                     "3.500000000000 0.200000000000 0.000000000000")))
