#lang racket/base

(require racket/format
         racket/math
         "core.rkt")

(provide finite-flonum
         coordinate-string
         require-segmentation!)

(define (finite-flonum who value)
  (define converted (exact->inexact value))
  (unless (and (real? converted)
               (not (nan? converted))
               (not (infinite? converted)))
    (error who "cannot export non-finite numeric value ~e" value))
  converted)

(define (coordinate-string who value)
  (~r (finite-flonum who value) #:precision '(= 12)))

(define (require-segmentation! who)
  (define value (maximum-segment-length))
  (unless (and (real? value) (> value 0))
    (error who "maximum-segment-length must be set to a positive value before export"))
  value)
