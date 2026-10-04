#lang antenna-turtle

(provide exact-result precedence-result lexical-result nested-result
         escaped-result comparison-result)

(define divisor 7)
(define exact-result {360 / divisor})
(define precedence-result {1 + 2 * 3})
(define lexical-result {precedence-result * 2})
(define nested-result {{1 + 2} * 3})
(define escaped-result {2 * ~(sqrt 9)})
(define comparison-result {1 + 2 * 3 = 7})

(maximum-segment-length {1 / 10})
(wire-diameter {2 * millimeter})

(with-pen
  (move forward {1 + 2 * 3}
        up {divisor - 6}))
