#lang racket/base

(require (except-in "material.rkt" dielectric conductor)
         (for-syntax racket/base racket/list syntax/parse))

(provide (all-from-out "material.rkt")
         dielectric
         conductor)

(begin-for-syntax
  (define (settings who stx items allowed description)
    (define values (syntax->list items))
    (when (odd? (length values))
      (raise-syntax-error who description stx))
    (define result (make-hasheq))
    (for ([offset (in-range 0 (length values) 2)])
      (define key-stx (list-ref values offset))
      (unless (identifier? key-stx)
        (raise-syntax-error who "expected a contextual setting name" stx key-stx))
      (define key (syntax-e key-stx))
      (unless (memq key allowed)
        (raise-syntax-error who description stx key-stx))
      (when (hash-has-key? result key)
        (raise-syntax-error who "setting may be specified only once" stx key-stx))
      (hash-set! result key (list-ref values (add1 offset))))
    result)

  (define (name-expression value)
    (if (identifier? value) #`'#,(syntax-e value) value))

  (define (optional-keyword values key keyword)
    (if (hash-has-key? values key)
        (list keyword (hash-ref values key))
        '()))

  (define (loss-expression value stx)
    (syntax-parse value
      [(narrow:id tangent frequency)
       #:when (eq? (syntax-e #'narrow) 'narrow)
       #'(make-narrow-loss tangent frequency)]
      [(broad:id tangent lower upper)
       #:when (eq? (syntax-e #'broad) 'broad)
       #'(make-broad-loss tangent lower upper)]
      [(broad:id tangent lower upper at:id reference)
       #:when (and (eq? (syntax-e #'broad) 'broad)
                   (eq? (syntax-e #'at) 'at))
       #'(make-broad-loss tangent lower upper
                          #:reference-frequency reference)]
      [(relax:id pole ...+)
       #:when (eq? (syntax-e #'relax) 'relax)
       (define pole-expressions
         (for/list ([item (in-list (syntax->list #'(pole ...)))])
           (syntax-parse item
             [(delta time) #'(list delta time)]
             [_ (raise-syntax-error
                 'dielectric
                 "each relax pole must be (delta-epsilon relaxation-time)"
                 stx item)])))
       #`(make-relaxation-loss (list #,@pole-expressions))]
      [_ value])))

;; These forms deliberately live outside the optional solid DSL. Material
;; declarations describe electromagnetic intent and are useful to NEC2C even
;; when the native Manifold library is unavailable.
(define-syntax (dielectric stx)
  (syntax-parse stx
    [(_ argument ...)
     (define arguments (syntax->list #'(argument ...)))
     (if (ormap keyword? (map syntax-e arguments))
         #'(make-dielectric argument ...)
         (let* ([values
                 (settings
                  'dielectric stx #'(argument ...)
                  '(name er ur relative-permittivity relative-permeability
                         loss loss-tangent loss-frequency conductivity)
                  (string-append
                   "expected name, er, ur, relative-permittivity, or "
                   "relative-permeability, loss, loss-tangent, loss-frequency, "
                   "or conductivity setting/value pairs"))]
                [epsilon
                 (or (hash-ref values 'er #f)
                     (hash-ref values 'relative-permittivity #f))]
                [mu
                 (or (hash-ref values 'ur #f)
                     (hash-ref values 'relative-permeability #'1))]
                [name (hash-ref values 'name #''dielectric)])
           (unless epsilon
             (raise-syntax-error
              'dielectric "er or relative-permittivity is required" stx))
           #`(make-dielectric
              #:name #,(name-expression name)
              #:relative-permittivity #,epsilon
              #:relative-permeability #,mu
              #,@(if (hash-has-key? values 'loss)
                     (list #'#:loss
                           (loss-expression (hash-ref values 'loss) stx))
                     '())
              #,@(optional-keyword values 'loss-tangent #'#:loss-tangent)
              #,@(optional-keyword values 'loss-frequency #'#:loss-frequency)
              #,@(optional-keyword values 'conductivity #'#:conductivity))))]))

(define-syntax (conductor stx)
  (syntax-parse stx
    [(_ argument ...)
     (define arguments (syntax->list #'(argument ...)))
     (if (ormap keyword? (map syntax-e arguments))
         #'(make-conductor argument ...)
         (let ([values
                (settings 'conductor stx #'(argument ...)
                          '(name conductivity sheet-thickness)
                          (string-append
                           "expected name, conductivity, or sheet-thickness "
                           "setting/value pairs"))])
           (define conductivity (hash-ref values 'conductivity #f))
           (unless conductivity
             (raise-syntax-error 'conductor "conductivity is required" stx))
           (define name (hash-ref values 'name #''conductor))
           #`(make-conductor
              #:name #,(name-expression name)
              #:conductivity #,conductivity
              #,@(optional-keyword values 'sheet-thickness
                                    #'#:sheet-thickness))))]))
