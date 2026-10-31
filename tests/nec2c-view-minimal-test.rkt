#lang racket/base

(require rackunit
         "../antenna-turtle/main.rkt")

;; This module must load even when Manifold is not installed: these viewers
;; render wire/NEC2C data and are independent of the optional solid backend.
(check-true (procedure? show-vswr-sweep))
(check-true (procedure? show-radiation-cut))
(check-true (procedure? show-radiation-pattern-3d))
(check-true (procedure? write-html-report))
;; Network measurements and their conversion helpers apply to NEC2C wire
;; results too, so they remain available when the optional OpenEMS/Manifold
;; backend cannot load.
(check-true (procedure? vswr-at))
(check-true (procedure? impedance->vswr))
(check-true (procedure? return-loss->vswr))
(define-values (_required-comparison-keywords comparison-keywords)
  (procedure-keywords show-radiation-comparison))
(check-not-false (member '#:difference? comparison-keywords))
(check-not-false (member '#:difference-range-db comparison-keywords))
