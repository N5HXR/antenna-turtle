#lang racket/base

;; Headless data structures and selection logic shared by the NEC2C graph
;; builders and the lazily loaded GUI viewer.

(provide
 (struct-out cursor-series)
 (struct-out cursor-selection)
 (struct-out plot-legend-item)
 nearest-cursor-sample)

(struct cursor-series (label points color) #:transparent)
(struct cursor-selection (series point distance-squared) #:transparent)
;; A deliberately small, backend-independent legend description. Keeping it
;; outside the GUI module lets headless renderer builders describe legends
;; without loading racket/gui/base.
(struct plot-legend-item (label color style kind) #:transparent)

(define (finite-point? point)
  (and (vector? point)
       (>= (vector-length point) 2)
       (rational? (vector-ref point 0))
       (rational? (vector-ref point 1))))

;; Find the actual harvested sample nearest the cursor after transforming plot
;; coordinates into display coordinates. Selecting samples rather than an
;; interpolated point ensures that a data tip never invents a measurement.
(define (nearest-cursor-sample series-list cursor-x cursor-y plot->display)
  (for*/fold ([best #f])
             ([series (in-list series-list)]
              [point (in-list (cursor-series-points series))]
              #:when (finite-point? point))
    (define display-point
      (plot->display
       (vector (vector-ref point 0) (vector-ref point 1))))
    (define dx (- (vector-ref display-point 0) cursor-x))
    (define dy (- (vector-ref display-point 1) cursor-y))
    (define distance-squared (+ (* dx dx) (* dy dy)))
    (if (or (not best)
            (< distance-squared
               (cursor-selection-distance-squared best)))
        (cursor-selection series point distance-squared)
        best)))
