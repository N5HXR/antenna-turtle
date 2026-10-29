#lang racket/base

(require "material.rkt"
         "nec2c-dielectric.rkt"
         (for-syntax racket/base racket/list syntax/parse))

(provide cuboid)

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
    (cond
      [(not value) #'(gensym 'cuboid)]
      [(identifier? value) #`'#,(syntax-e value)]
      [else value]))

  (define (anchor-expression value stx)
    (cond
      [(not value) #''center]
      [(identifier? value)
       #`'#,(syntax-e value)]
      [else value])))

;; This is the cuboid implementation used by the minimal language when the
;; optional solid backend is unavailable. With Manifold present, the full
;; solid DSL provides the same syntax and records the same analytic primitive.
(define-syntax (cuboid stx)
  (syntax-parse stx
    [(_ old-name:id setting ...)
     #:when (not (memq (syntax-e #'old-name)
                       '(name size length width height material anchor)))
     (raise-syntax-error
      'cuboid "positional names are not supported; use name VALUE" stx #'old-name)]
    [(_ setting ...)
     (define values
       (settings
        'cuboid stx #'(setting ...)
        '(name size length width height material anchor)
        "expected dimensions, material, or anchor setting/value pairs"))
     (define size (hash-ref values 'size #f))
     (define length (hash-ref values 'length #f))
     (define width (hash-ref values 'width #f))
     (define height (hash-ref values 'height #f))
     (when (and size (or length width height))
       (raise-syntax-error 'cuboid "use either size or named dimensions" stx))
     (unless (or size (and length width height))
       (raise-syntax-error
        'cuboid "size or length, width, and height are required" stx))
     (define dimensions (or size #`(list #,length #,width #,height)))
     #`(add-model-cuboid
        #,(name-expression (hash-ref values 'name #f))
        #,(hash-ref values 'material #'pec)
        #,dimensions
        #:anchor #,(anchor-expression (hash-ref values 'anchor #f) stx))]))
