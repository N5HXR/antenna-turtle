#lang racket/base

(require rackunit
         "../antenna-turtle/main.rkt")

;; This module must load even when Manifold is not installed: these viewers
;; render wire/NEC2C data and are independent of the optional solid backend.
(check-true (procedure? show-vswr-sweep))
(check-true (procedure? show-radiation-cut))
(check-true (procedure? show-radiation-pattern-3d))
(check-true (procedure? show-near-field))
(check-true (procedure? show-polarization-surface-poc))
(check-true (procedure? show-near-field-poynting-particles))
(check-true (procedure? show-radiation-palette-lab))
(check-true (procedure? write-html-report))
(check-true (procedure? html-auto-report))
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
(define-values (_required-palette-lab-keywords palette-lab-keywords)
  (procedure-keywords show-radiation-palette-lab))
(check-not-false (member '#:spherical-grid? palette-lab-keywords))
(define-values (_required-poc-keywords poc-keywords)
  (procedure-keywords show-polarization-surface-poc))
(check-not-false (member '#:mesh-step poc-keywords))
(check-not-false (member '#:width poc-keywords))
(check-not-false (member '#:height poc-keywords))
(define-values (_required-radiation-keywords radiation-keywords)
  (procedure-keywords show-radiation-pattern-opengl))
(check-not-false (member '#:view radiation-keywords))
(define-values (required-near-field-keywords near-field-keywords)
  (procedure-keywords show-near-field))
(check-not-false (member '#:view required-near-field-keywords))
(check-not-false (member '#:section near-field-keywords))
(check-exn #rx"'gain 'polarization"
           (lambda ()
             (show-radiation-pattern-opengl 'unused #:view 'unknown)))
(check-exn #rx"'polarization"
           (lambda () (show-near-field 'unused #:view 'unknown)))
(define-values (_required-particle-keywords particle-keywords)
  (procedure-keywords show-near-field-poynting-particles))
(check-not-false (member '#:mode particle-keywords))
(check-not-false (member '#:particles particle-keywords))
(check-not-false (member '#:spawn-rate particle-keywords))
(check-not-false (member '#:trail-length particle-keywords))
(check-not-false (member '#:jitter particle-keywords))
(check-not-false (member '#:particle-size particle-keywords))
(define-values (_required-auto-report-keywords auto-report-keywords)
  (procedure-keywords html-auto-report))
(check-not-false (member '#:pattern auto-report-keywords))
(check-not-false (member '#:pattern-step auto-report-keywords))
(check-exn #rx"nec2c-pattern-grid"
           (lambda ()
             (html-auto-report "unused.html" #:pattern 'not-a-pattern)))
(check-exn #rx"positive-real"
           (lambda ()
             (html-auto-report "unused.html" #:pattern-step 0)))
