#lang racket/base

(require racket/list
         "measurement-network.rkt"
         "measurement-radiation.rkt"
         "nec2c.rkt")

(provide
 (except-out (all-from-out "measurement-network.rkt")
             measurement-network-frequencies measurement-network-ports)
 (except-out (all-from-out "measurement-radiation.rkt")
             measurement-pattern-frequencies)
 measurement-frequencies
 measurement-frequency-range
 measurement-ports)

(define (measurement-frequencies result)
  (if (or (nec2c-pattern? result)
          (nec2c-pattern-grid? result)
          (nec2c-gain-sweep-result? result))
      (measurement-pattern-frequencies result)
      (measurement-network-frequencies result)))

(define (measurement-frequency-range result)
  (define frequencies (measurement-frequencies result))
  (if (null? frequencies)
      #f
      (list (first frequencies) (last frequencies))))

(define (measurement-ports result)
  (measurement-network-ports result))
