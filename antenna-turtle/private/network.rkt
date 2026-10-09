#lang racket/base

(provide
 (struct-out network-sample)
 (struct-out network-sweep)
 reflection-magnitude->vswr)

;; Solver-neutral network data used by plotting and future multi-port work.
;; A flat sample list naturally accommodates more than one named port at each
;; frequency without imposing either backend's native result hierarchy.
(struct network-sample
  (port-name frequency-mhz reflection-coefficient impedance s11-db vswr)
  #:transparent)

(struct network-sweep (backend run reference-impedance samples) #:transparent)

(define (reflection-magnitude->vswr magnitude*)
  (if (>= magnitude* 1)
      +inf.0
      (/ (+ 1 magnitude*) (- 1 magnitude*))))
