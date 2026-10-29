#lang racket/base

(require rackunit
         (except-in "../antenna-turtle/private/core.rkt" cylinder scale)
         "../antenna-turtle/private/material-dsl.rkt"
         "../antenna-turtle/private/nec2c-dielectric.rkt"
         "../antenna-turtle/private/model-cuboid-dsl.rkt")

;; This test intentionally avoids main.rkt and every Manifold-backed module.
;; It protects the minimal-installation form that main.rkt selects when the
;; optional native library is unavailable.
(test-case "the shared cuboid syntax records analytic geometry without Manifold"
  (reset-model!)
  (define medium (dielectric name medium er 2.5))
  (define placed
    (cuboid name obstacle size '(1 2 3) material medium anchor bottom))
  (check-true (model-cuboid? placed))
  (check-equal? (model-cuboid-name placed) 'obstacle)
  (check-equal? (model-cuboid-material placed) medium)
  (define-values (minimum maximum) (model-cuboid-bounds placed))
  (check-equal? minimum '(-1/2 -1 0))
  (check-equal? maximum '(1/2 1 3)))
