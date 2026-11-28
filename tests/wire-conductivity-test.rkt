#lang racket

(require rackunit
         racket/string
         "../antenna-turtle/main.rkt"
         (only-in "../antenna-turtle/private/export-nec2c.rkt"
                  write-nec2c-deck))

(define (draw-wire length)
  (with-wire (forward length)))

(define (deck-string)
  (call-with-output-string write-nec2c-deck))

(test-case "wire material and empirical conductivity are captured per edge"
  (reset-model!)
  (wire-material copper)
  (draw-wire 1)
  (wire-conductivity 6000000)
  (turn right 90)
  (draw-wire 1)
  (wire-conductivity #f)
  (turn right 90)
  (draw-wire 1)
  (define edges (model-edges))
  (check-eq? (wire-edge-material (first edges)) copper)
  (check-equal? (map wire-edge-conductivity edges)
                (list 58000000.0 6000000 #f))
  (check-eq? (wire-edge-material (third edges)) pec)
  (check-false (wire-conductivity)))

(test-case "model accepts either a wire material or raw conductivity"
  (reset-model!)
  (model wire-material steel)
  (check-eq? (wire-material) steel)
  (check-equal? (wire-conductivity) 6000000.0)
  (reset-model!)
  (model wire-conductivity 41000000)
  (check-equal? (wire-conductivity) 41000000))

(test-case "with-conductivity nests and restores after failure"
  (reset-model!)
  (wire-material steel)
  (with-conductivity 58000000
    (draw-wire 1)
    (with-conductivity 35000000
      (turn right 90)
      (draw-wire 1))
    (turn right 90)
    (draw-wire 1))
  (turn right 90)
  (draw-wire 1)
  (check-equal? (map wire-edge-conductivity (model-edges))
                (list 58000000 35000000 58000000 6000000.0))
  (check-exn
   exn:fail?
   (lambda ()
     (with-conductivity 63000000
       (error 'test "leave scope abnormally"))))
  (check-eq? (wire-material) steel))

(test-case "clear preserves the declared material and reset restores PEC"
  (reset-model!)
  (wire-material brass)
  (clear-wires)
  (check-eq? (wire-material) brass)
  (reset-model!)
  (check-eq? (wire-material) pec)
  (check-false (wire-conductivity)))

(test-case "reflection copies wire conductivity"
  (reset-model!)
  (wire-material aluminum)
  (reflect up
    (with-wire (move forward 1 up 1)))
  (check-equal? (length (model-edges)) 2)
  (check-equal? (map wire-edge-conductivity (model-edges))
                (list 35000000.0 35000000.0)))

(test-case "NEC2C emits compact uniform and tagged mixed LD 5 cards"
  (reset-model!)
  (model frequency 30 max-length 1/10 wire-material copper)
  (draw-wire 1)
  (define uniform (deck-string))
  (check-true
   (string-contains? uniform "LD 5 0 0 0 58000000.000000000000"))
  (check-equal? (length (regexp-match* #rx"(?m:^LD 5 )" uniform)) 1)

  (reset-model!)
  (model frequency 30 max-length 1/10)
  (wire-material copper)
  (draw-wire 1)
  (wire-material steel)
  (turn right 90)
  (draw-wire 1)
  (wire-material pec)
  (turn right 90)
  (draw-wire 1)
  (define mixed (deck-string))
  (check-true
   (string-contains? mixed "LD 5 1 0 0 58000000.000000000000"))
  (check-true
   (string-contains? mixed "LD 5 2 0 0 6000000.000000000000"))
  (check-equal? (length (regexp-match* #rx"(?m:^LD 5 )" mixed)) 2))

(test-case "wire material validation rejects nonconductors and bad values"
  (reset-model!)
  (check-exn exn:fail:contract?
             (lambda () (wire-material air)))
  (check-exn exn:fail?
             (lambda () (wire-conductivity 0)))
  (check-exn exn:fail?
             (lambda () (wire-conductivity +nan.0))))
