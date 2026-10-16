#lang racket/base

(provide (struct-out lumped-component))

;; The direction is the two-terminal electrical axis. The transverse vectors
;; orient the component's rectangular simulation region.
(struct lumped-component
  (name resistance inductance capacitance topology caps
        center direction transverse-u transverse-v
        gap width depth priority placement-transform)
  #:transparent)
