#lang racket/base

(require "material.rkt")

(provide silver copper gold aluminum brass steel)

;; Nominal room-temperature bulk conductivities in S/m. Steel deliberately
;; represents a generic nonmagnetic, middle-of-the-road alloy; magnetic
;; material modeling is deferred to a later revision.
(define silver   (conductor #:name 'silver   #:conductivity 6.3e7))
(define copper   (conductor #:name 'copper   #:conductivity 5.8e7))
(define gold     (conductor #:name 'gold     #:conductivity 4.1e7))
(define aluminum (conductor #:name 'aluminum #:conductivity 3.5e7))
(define brass    (conductor #:name 'brass    #:conductivity 1.6e7))
(define steel    (conductor #:name 'steel    #:conductivity 6.0e6))
