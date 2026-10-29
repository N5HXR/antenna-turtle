#lang racket/base

(require racket/list
         "wire-lumped.rkt"
         (for-syntax racket/base racket/list syntax/parse))

(provide lumped-element)

(define (transverse-size who value)
  (cond
    [(real? value) (values value value)]
    [(and (list? value) (= (length value) 2))
     (values (first value) (second value))]
    [else
     (raise-argument-error who "(or/c real? (list/c real? real?))" value)]))

(begin-for-syntax
  (define valid-directions
    '(forward forwards back backward backwards left right up down))

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

  (define (literal-expression value allowed who stx description [default #f])
    (cond
      [(not value) default]
      [(and (identifier? value) (memq (syntax-e value) allowed))
       #`'#,(syntax-e value)]
      [else (raise-syntax-error who description stx value)]))

  (define (name-expression value)
    (if (identifier? value) #`'#,(syntax-e value) value))

  (define (optional-keyword values key keyword)
    (if (hash-has-key? values key)
        (list keyword (hash-ref values key))
        '())))

(define-syntax (lumped-element stx)
  (syntax-parse stx
    [(_ direction:id setting ...)
     (unless (memq (syntax-e #'direction) valid-directions)
       (raise-syntax-error 'lumped-element "expected a turtle direction" stx #'direction))
     (define values
       (settings
        'lumped-element stx #'(setting ...)
        '(name resistance inductance capacitance topology caps
               gap width depth size anchor priority precedence)
        (string-append
         "expected name, resistance, inductance, capacitance, topology, caps, "
         "gap, width, depth, size, anchor, priority, or precedence setting/value pairs")))
     (unless (hash-has-key? values 'gap)
       (raise-syntax-error 'lumped-element "gap setting is required" stx))
     (unless (ormap (lambda (key) (hash-has-key? values key))
                    '(resistance inductance capacitance))
       (raise-syntax-error 'lumped-element "an electrical value is required" stx))
     (when (and (hash-has-key? values 'size)
                (or (hash-has-key? values 'width) (hash-has-key? values 'depth)))
       (raise-syntax-error 'lumped-element "use either size or width/depth" stx))
     (when (not (eq? (hash-has-key? values 'width)
                     (hash-has-key? values 'depth)))
       (raise-syntax-error 'lumped-element "supply both width and depth" stx))
     (define topology
       (and (hash-has-key? values 'topology)
            (literal-expression (hash-ref values 'topology) '(series parallel)
                                'lumped-element stx
                                "topology must be series or parallel")))
     (define anchor
       (and (hash-has-key? values 'anchor)
            (literal-expression (hash-ref values 'anchor) '(start center end)
                                'lumped-element stx
                                "anchor must be start, center, or end")))
     (define arguments
       (append
        (if (hash-has-key? values 'name)
            (list #'#:name (name-expression (hash-ref values 'name))) '())
        (optional-keyword values 'resistance #'#:resistance)
        (optional-keyword values 'inductance #'#:inductance)
        (optional-keyword values 'capacitance #'#:capacitance)
        (if topology (list #'#:topology topology) '())
        (optional-keyword values 'caps #'#:caps)
        (list #'#:gap (hash-ref values 'gap))
        (if anchor (list #'#:anchor anchor) '())
        (optional-keyword values 'priority #'#:priority)
        (optional-keyword values 'precedence #'#:precedence)))
     (cond
       [(hash-has-key? values 'size)
        (define size (hash-ref values 'size))
        #`(let-values ([(width depth) (transverse-size 'lumped-element #,size)])
            (add-lumped-element-declaration
             '#,(syntax-e #'direction) #:width width #:depth depth #,@arguments))]
       [(hash-has-key? values 'width)
        #`(add-lumped-element-declaration
           '#,(syntax-e #'direction)
           #:width #,(hash-ref values 'width)
           #:depth #,(hash-ref values 'depth)
           #,@arguments)]
       [else
        #`(add-lumped-element-declaration '#,(syntax-e #'direction) #,@arguments)])]
    [(_ . _)
     (raise-syntax-error
      'lumped-element
      "expected (lumped-element DIRECTION setting value ...)" stx)]))
