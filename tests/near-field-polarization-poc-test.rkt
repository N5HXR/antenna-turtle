#lang racket/base

(require rackunit
         "../antenna-turtle/private/nec2c.rkt"
         "../antenna-turtle/private/nec2c-view.rkt"
         "../antenna-turtle/private/visualization-handle.rkt")

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
