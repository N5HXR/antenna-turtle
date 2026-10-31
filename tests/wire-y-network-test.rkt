#lang racket

(require rackunit
         racket/port
         "../antenna-turtle/main.rkt"
         "../antenna-turtle/private/export-nec2c.rkt")

(test-case "two-port-y exports a reciprocal NEC NT card"
  (reset-model!)
  (model title "Y-network fixture" frequency 14.1)
  (define primary
    (wire-port up name primary gap centimeter))
  (move forward meter)
  (define secondary
    (wire-port forward name secondary gap centimeter))
  (two-port-y
   name transformer-4:1
   input primary
   output secondary
   y11 999.968228-0.002500i
   y12 -499.984114+0.000750i
   y22 249.992057-0.000625i)
  (coax name feedline
        output primary
        impedance 50
        velocity-factor 0.66
        diameter centimeter
        input-gap centimeter
        input-direction up
        feed input
        (move down meter))
  (define deck (call-with-output-string write-nec2c-deck))
  (check-regexp-match
   #rx"NT 1 1 2 1 999\\.9682280* -0\\.0025000* -499\\.9841140* 0\\.0007500* 249\\.9920570* -0\\.0006250*"
   deck)
  (check-regexp-match #rx"TL 4 1 1 1 50" deck)
  (check-regexp-match #rx"EX 0 4 1 0 1\\.0+ 0\\.0+" deck))

(test-case "two-port-y requires different registered ports"
  (reset-model!)
  (model frequency 14.1)
  (define port (wire-port forward name only gap centimeter))
  (check-exn
   #rx"input and output must be different ports"
   (lambda ()
     (two-port-y
      input port output port
      y11 1 y12 0 y22 1))))

(test-case "ideal-transformer creates a finite turns-ratio constraint"
  (reset-model!)
  (model frequency 14.1)
  (define primary
    (wire-port up name primary gap centimeter))
  (move forward meter)
  (define secondary
    (wire-port forward name secondary gap centimeter))
  (define transformer
    (ideal-transformer
     name transformer-4:1
     input primary
     output secondary
     turns-ratio 2))
  (check-equal? (wire-y-network-y11 transformer) 1000.0)
  (check-equal? (wire-y-network-y12 transformer) -500.0)
  (check-equal? (wire-y-network-y22 transformer) 250.0)
  (define deck (call-with-output-string write-nec2c-deck))
  (check-regexp-match
   #rx"NT 1 1 2 1 1000\\.0+ 0\\.0+ -500\\.0+ 0\\.0+ 250\\.0+ 0\\.0+"
   deck))

(test-case "ideal-transformer validates its finite approximation"
  (reset-model!)
  (define primary (wire-port up name primary gap centimeter))
  (move forward meter)
  (define secondary (wire-port up name secondary gap centimeter))
  (check-exn
   #rx"turns ratio must be a positive finite real"
   (lambda ()
     (ideal-transformer input primary output secondary turns-ratio 0)))
  (check-exn
   #rx"series resistance must be a positive finite real"
   (lambda ()
     (ideal-transformer input primary output secondary
                        turns-ratio 2 series-resistance 0))))
