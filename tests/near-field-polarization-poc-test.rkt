#lang racket/base

(require rackunit
         racket/list
         "../antenna-turtle/private/nec2c.rkt"
         "../antenna-turtle/private/nec2c-view.rkt"
         (only-in "../antenna-turtle/private/near-field-polarization-poc.rkt"
                  near-field-glyph-sample-indices)
         "../antenna-turtle/private/visualization-handle.rkt")

(test-case "near-field glyph samples are stable source indices"
  (define indices (near-field-glyph-sample-indices 101 8))
  (check-equal? (first indices) 0)
  (check-equal? (last indices) 100)
  (check-not-false (member 50 indices))
  (check-true (andmap exact-nonnegative-integer? indices))
  (check-true (<= 10 (length indices) 15))
  (check-equal? indices (near-field-glyph-sample-indices 101 8)))

(define section
  (nec2c-near-field-section
   'xy 'z 0.0 'x 'y
   '(-1.0 1.0) '(-1.0 1.0)
   (for*/list ([y '(-1.0 1.0)] [x '(-1.0 1.0)])
     (nec2c-near-field-sample
      x y 0.0 '(1+0i 0-1i 0.25+0.25i) '(0 0 0)))
   '(electric magnetic)))

(define result
  (nec2c-near-field-result
   (hash 'backend 'nec2c) 100.0 (list section) #f))

(test-case "near-field selected-point PoC opens with a 3D trajectory"
  (define handle
    (show-near-field-polarization-point-poc
     result #:width 720 #:height 520))
  (check-true (visualization-handle? handle))
  (check-true (visualization-open? handle))
  (visualization-close! handle))
