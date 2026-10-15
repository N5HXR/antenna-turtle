#lang racket/base

(require racket/format
         racket/list)

(provide report-near
         report-at-most
         report-at-least
         report-true
         report-reciprocity
         frequency-of-minimum
         frequency-of-maximum
         principal-degree-difference)

(define (status passed?) (if passed? "PASS" "CHECK"))

(define (report-near label actual expected
                     #:relative [relative-tolerance 0.05]
                     #:absolute [absolute-tolerance 0])
  (define error (magnitude (- actual expected)))
  (define allowance
    (max absolute-tolerance (* relative-tolerance (magnitude expected))))
  (define passed? (<= error allowance))
  (printf "~a  ~a: measured ~a; expected ~a; error ~a (limit ~a)\n"
          (status passed?) label actual expected error allowance)
  passed?)

(define (report-at-most label actual limit)
  (define passed? (<= actual limit))
  (printf "~a  ~a: measured ~a; expected <= ~a\n"
          (status passed?) label actual limit)
  passed?)

(define (report-at-least label actual limit)
  (define passed? (>= actual limit))
  (printf "~a  ~a: measured ~a; expected >= ~a\n"
          (status passed?) label actual limit)
  passed?)

(define (report-true label passed? [detail #f])
  (printf "~a  ~a~a\n" (status passed?) label
          (if detail (format ": ~a" detail) ""))
  passed?)

(define (report-reciprocity result frequency s-parameter-at
                            #:first [first 'input]
                            #:second [second 'output]
                            #:relative [relative-tolerance 0.02])
  (report-near
   (format "S~a~a reciprocity at ~a MHz" second first frequency)
   (s-parameter-at result frequency #:from first #:to second
                   #:interpolate? #t)
   (s-parameter-at result frequency #:from second #:to first
                   #:interpolate? #t)
   #:relative relative-tolerance
   #:absolute 1e-3))

(define (frequency-of-extreme result frequencies value-at better?)
  (for/fold ([best-frequency (first frequencies)]
             [best-value (value-at result (first frequencies))]
             #:result best-frequency)
            ([frequency (in-list (rest frequencies))])
    (define value (value-at result frequency))
    (if (better? value best-value)
        (values frequency value)
        (values best-frequency best-value))))

(define (frequency-of-minimum result frequencies value-at)
  (frequency-of-extreme result frequencies value-at <))

(define (frequency-of-maximum result frequencies value-at)
  (frequency-of-extreme result frequencies value-at >))

(define (principal-degree-difference left right)
  (define shifted (+ (- left right) 180.0))
  (- shifted (* 360.0 (floor (/ shifted 360.0))) 180.0))

(module+ test
  (require rackunit)
  (check-equal?
   (frequency-of-minimum #f '(1 2 3)
                         (lambda (_ frequency) (abs (- frequency 2))))
   2)
  (check-= (principal-degree-difference -170 170) 20 1e-12)
  (check-= (principal-degree-difference 170 -170) -20 1e-12))
