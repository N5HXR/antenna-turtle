#lang racket/base

(require rackunit
         "../antenna-turtle/private/amateur-bands.rkt"
         "../antenna-turtle/private/plot-cursor.rkt")

(test-case "only amateur allocations intersecting the sweep are selected"
  (check-equal?
   (map amateur-band-segment-name
        (visible-amateur-band-segments 13.5 25.0))
   '("20m" "17m" "15m" "12m")))

(test-case "discontinuous allocations remain discontinuous"
  (define sixty-meter-segments
    (visible-amateur-band-segments 5.3 5.45))
  (check-equal? (length sixty-meter-segments) 5)
  (check-true
   (for/and ([segment (in-list sixty-meter-segments)])
     (string=? (amateur-band-segment-name segment) "60m"))))

(test-case "band renderers neither appear nor affect non-frequency ranges"
  (define outside
    (cursor-series "outside"
                   (list (vector 31.0 1.0) (vector 49.0 2.0))
                   "steelblue"))
  (check-equal? (amateur-band-renderers (list outside)) '()))

(test-case "visible bands produce a fill and label overlay"
  (define hf
    (cursor-series "HF"
                   (list (vector 2.5 1.0) (vector 30.0 2.0))
                   "steelblue"))
  (check-equal? (length (amateur-band-renderers (list hf))) 2))
