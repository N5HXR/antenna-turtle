#lang racket/base

(require rackunit
         "../antenna-turtle/main.rkt")

;; This module must load even when Manifold is not installed: these viewers
;; render wire/NEC2C data and are independent of the optional solid backend.
(check-true (procedure? show-vswr-sweep))
(check-true (procedure? show-radiation-cut))
(check-true (procedure? show-radiation-pattern-3d))
