#lang racket/base

(require racket/list
         racket/math)

;; Solver-neutral requests for frequency-domain data retained by a simulation.
;; The request deliberately describes physical quantities rather than openEMS
;; dump types so future backends can implement the same contract.

(provide
 field-slice
 field-slice?
 field-slice-quantity
 field-slice-axis
 field-slice-position
 field-capture
 field-capture?
 field-capture-frequency
 field-capture-excitation
 field-capture-current
 field-capture-slices
 field-capture-volume
 field-capture-max-samples)

(struct captured-field-slice (quantity axis position) #:transparent)
(struct captured-field-request
  (frequency excitation current slices volume max-samples)
  #:transparent)

(define field-slice? captured-field-slice?)
(define field-slice-quantity captured-field-slice-quantity)
(define field-slice-axis captured-field-slice-axis)
(define field-slice-position captured-field-slice-position)

(define field-capture? captured-field-request?)
(define field-capture-frequency captured-field-request-frequency)
(define field-capture-excitation captured-field-request-excitation)
(define field-capture-current captured-field-request-current)
(define field-capture-slices captured-field-request-slices)
(define field-capture-volume captured-field-request-volume)
(define field-capture-max-samples captured-field-request-max-samples)

(define (finite-real? value)
  (and (real? value)
       (not (nan? (exact->inexact value)))
       (not (infinite? (exact->inexact value)))))

(define (field-slice quantity axis position)
  (unless (memq quantity '(electric magnetic))
    (raise-argument-error
     'field-slice "(or/c 'electric 'magnetic)" quantity))
  (unless (memq axis '(x y z))
    (raise-argument-error 'field-slice "(or/c 'x 'y 'z)" axis))
  (unless (finite-real? position)
    (raise-argument-error 'field-slice "finite-real?" position))
  (captured-field-slice quantity axis position))

(define (field-capture #:frequency frequency
                       #:excitation [excitation #f]
                       #:current [current #f]
                       #:slices [slices '()]
                       #:volume [volume '()]
                       #:max-samples [max-samples 250000])
  (unless (and (finite-real? frequency) (positive? frequency))
    (raise-argument-error 'field-capture "positive finite frequency in MHz"
                          frequency))
  (unless (or (not excitation) (symbol? excitation) (string? excitation))
    (raise-argument-error
     'field-capture "(or/c #f symbol? string?)" excitation))
  (unless (memq current '(#f conductors))
    (raise-argument-error
     'field-capture "(or/c #f 'conductors)" current))
  (unless (and (list? slices) (andmap field-slice? slices))
    (raise-argument-error 'field-capture "(listof field-slice?)" slices))
  (unless (and (list? volume)
               (andmap (lambda (quantity)
                         (memq quantity '(electric magnetic)))
                       volume)
               (= (length volume) (length (remove-duplicates volume))))
    (raise-argument-error
     'field-capture
     "a duplicate-free list containing 'electric and/or 'magnetic"
     volume))
  (unless (exact-positive-integer? max-samples)
    (raise-argument-error 'field-capture "exact-positive-integer?"
                          max-samples))
  (unless (or current (pair? slices) (pair? volume))
    (raise-arguments-error
     'field-capture
     "at least one current, field-slice, or field-volume recording must be requested"
     "current" current
     "slices" slices
     "volume" volume))
  (captured-field-request
   frequency excitation current slices volume max-samples))

(module+ test
  (require rackunit)
  (define slice (field-slice 'electric 'z 0))
  (define capture
    (field-capture #:frequency 915 #:current 'conductors
                   #:slices (list slice)))
  (check-equal? (field-capture-frequency capture) 915)
  (check-equal? (field-slice-axis slice) 'z)
  (check-equal?
   (field-capture-volume
    (field-capture #:frequency 915 #:volume '(electric magnetic)))
   '(electric magnetic))
  (check-exn exn:fail:contract?
             (lambda () (field-capture #:frequency 915)))
  (check-exn exn:fail:contract?
             (lambda ()
               (field-capture #:frequency 915 #:volume '(electric electric))))
  (check-exn exn:fail:contract?
             (lambda () (field-slice 'power 'z 0))))
