#lang racket/base

(require "material.rkt")

(provide silver copper gold aluminum brass steel
         air fr4 ptfe teflon
         rogers-4003c rogers-4350b rogers-5880)

;; Nominal room-temperature bulk conductivities in S/m. Steel deliberately
;; represents a generic nonmagnetic, middle-of-the-road alloy; magnetic
;; material modeling is deferred to a later revision.
(define silver   (conductor #:name 'silver   #:conductivity 6.3e7))
(define copper   (conductor #:name 'copper   #:conductivity 5.8e7
                            #:sheet-thickness 35e-6))
(define gold     (conductor #:name 'gold     #:conductivity 4.1e7))
(define aluminum (conductor #:name 'aluminum #:conductivity 3.5e7))
(define brass    (conductor #:name 'brass    #:conductivity 1.6e7))
(define steel    (conductor #:name 'steel    #:conductivity 6.0e6))

;; Nominal room-temperature substrate values.  These are convenient starting
;; points rather than substitutes for a laminate vendor's frequency-specific
;; datasheet.  Loss tangent uses the model center frequency by default.
(define air (dielectric #:name 'air #:relative-permittivity 1.0))
(define fr4
  (dielectric #:name 'fr4 #:relative-permittivity 4.4 #:loss-tangent 0.015))
(define ptfe
  (dielectric #:name 'ptfe #:relative-permittivity 2.1 #:loss-tangent 0.0002))
(define teflon ptfe)
(define rogers-4003c
  (dielectric #:name 'rogers-4003c #:relative-permittivity 3.55
              #:loss-tangent 0.0027))
(define rogers-4350b
  (dielectric #:name 'rogers-4350b #:relative-permittivity 3.66
              #:loss-tangent 0.0037))
(define rogers-5880
  (dielectric #:name 'rogers-5880 #:relative-permittivity 2.2
              #:loss-tangent 0.0009))
