#lang racket/base

(require "wire-network.rkt"
         "coax-catalog.rkt"
         "core.rkt"
         (for-syntax racket/base racket/list syntax/parse))

(provide wire-port transmission-line two-port-y ideal-transformer coax)

(begin-for-syntax
  (define valid-directions
    '(forward forwards back backward backwards left right up down))

  (define (name-expression value)
    (if (identifier? value) #`'#,(syntax-e value) value))

  (define (literal-direction value who stx)
    (unless (and (identifier? value)
                 (memq (syntax-e value) valid-directions))
      (raise-syntax-error who "expected a turtle direction" stx value))
    #`'#,(syntax-e value))

  (define (literal value allowed who stx description)
    (unless (and (identifier? value) (memq (syntax-e value) allowed))
      (raise-syntax-error who description stx value))
    #`'#,(syntax-e value))

  (define (coax-type-expression value who stx)
    (unless (identifier? value)
      (raise-syntax-error who "coax type must be an identifier, such as rg58" stx value))
    #`(coax-spec-ref '#,(syntax-e value)))

  ;; In declarative connection fields, an unbound identifier names a port in
  ;; the current model.  A bound identifier remains an ordinary expression so
  ;; existing models that save a port object in a Racket variable still work.
  (define (port-reference-expression value)
    (if (and (identifier? value) (not (identifier-binding value)))
        #`'#,(syntax-e value)
        value))

  (define (parse-leading-settings who stx items allowed)
    (let loop ([remaining (syntax->list items)] [result (make-hasheq)])
      (cond
        [(and (pair? remaining)
              (identifier? (car remaining))
              (memq (syntax-e (car remaining)) allowed))
         (when (null? (cdr remaining))
           (raise-syntax-error who "setting is missing its value" stx (car remaining)))
         (define key-stx (car remaining))
         (define key (syntax-e key-stx))
         (when (hash-has-key? result key)
           (raise-syntax-error who "setting may be specified only once" stx key-stx))
         (hash-set! result key (cadr remaining))
         (loop (cddr remaining) result)]
        [else (values result remaining)])))

  (define (require-setting who stx values key)
    (unless (hash-has-key? values key)
      (raise-syntax-error who (format "~a setting is required" key) stx))
    (hash-ref values key))

  (define (optional-keyword settings key keyword [convert (lambda (value) value)])
    (if (hash-has-key? settings key)
        (list keyword (convert (hash-ref settings key)))
        '())))

(define-syntax (wire-port stx)
  (syntax-parse stx
    [(_ port-name:id direction:id setting ...)
     #:when (memq (syntax-e #'direction) valid-directions)
     (define-values (values body)
       (parse-leading-settings 'wire-port stx #'(setting ...)
                               '(gap diameter anchor feed)))
     (unless (null? body)
       (raise-syntax-error 'wire-port "unexpected expression after settings" stx
                           (car body)))
     (define arguments
       (append
        (list #'#:name #`'#,(syntax-e #'port-name)
              #'#:gap (require-setting 'wire-port stx values 'gap))
        (optional-keyword values 'diameter #'#:diameter)
        (optional-keyword
         values 'feed #'#:feed-name
         (lambda (value)
           #`(format "~a" #,(name-expression value))))
        (optional-keyword
         values 'anchor #'#:anchor
         (lambda (value)
           (literal value '(start center end) 'wire-port stx
                    "anchor must be start, center, or end")))))
     #`(add-wire-port-declaration '#,(syntax-e #'direction) #,@arguments)]
    [(_ direction:id setting ...)
     (unless (memq (syntax-e #'direction) valid-directions)
       (raise-syntax-error 'wire-port "expected a turtle direction" stx #'direction))
     (define-values (values body)
       (parse-leading-settings 'wire-port stx #'(setting ...)
                               '(name gap diameter anchor feed)))
     (unless (null? body)
       (raise-syntax-error 'wire-port "unexpected expression after settings" stx
                           (car body)))
     (define gap (require-setting 'wire-port stx values 'gap))
     (define arguments
       (append
        (optional-keyword values 'name #'#:name name-expression)
        (list #'#:gap gap)
        (optional-keyword values 'diameter #'#:diameter)
        (optional-keyword
         values 'feed #'#:feed-name
         (lambda (value)
           #`(format "~a" #,(name-expression value))))
        (optional-keyword
         values 'anchor #'#:anchor
         (lambda (value)
           (literal value '(start center end) 'wire-port stx
                    "anchor must be start, center, or end")))))
     #`(add-wire-port-declaration '#,(syntax-e #'direction) #,@arguments)]
    [(_ . _)
     (raise-syntax-error
      'wire-port
      "expected (wire-port DIRECTION setting value ...)" stx)]))

(define-syntax (transmission-line stx)
  (syntax-parse stx
    [(_ setting ...)
     (define-values (values body)
       (parse-leading-settings
        'transmission-line stx #'(setting ...)
        '(name input output impedance physical-length velocity-factor)))
     (unless (null? body)
       (raise-syntax-error 'transmission-line
                           "unexpected expression after settings" stx (car body)))
     (define arguments
       (append
        (optional-keyword values 'name #'#:name name-expression)
        (list #'#:input
              (port-reference-expression
               (require-setting 'transmission-line stx values 'input))
              #'#:output
              (port-reference-expression
               (require-setting 'transmission-line stx values 'output)))
        (optional-keyword values 'impedance #'#:impedance)
        (list #'#:physical-length
              (require-setting 'transmission-line stx values 'physical-length)
              #'#:velocity-factor
              (require-setting 'transmission-line stx values 'velocity-factor))))
     #`(add-transmission-line-declaration #,@arguments)]
    [(_ . _)
     (raise-syntax-error
      'transmission-line
      "expected (transmission-line setting value ...)" stx)]))

(define-syntax (two-port-y stx)
  (syntax-parse stx
    [(_ setting ...)
     (define-values (values body)
       (parse-leading-settings
        'two-port-y stx #'(setting ...)
        '(name input output y11 y12 y22)))
     (unless (null? body)
       (raise-syntax-error 'two-port-y
                           "unexpected expression after settings" stx
                           (car body)))
     (define arguments
       (append
        (optional-keyword values 'name #'#:name name-expression)
        (list #'#:input
              (port-reference-expression
               (require-setting 'two-port-y stx values 'input))
              #'#:output
              (port-reference-expression
               (require-setting 'two-port-y stx values 'output))
              #'#:y11 (require-setting 'two-port-y stx values 'y11)
              #'#:y12 (require-setting 'two-port-y stx values 'y12)
              #'#:y22 (require-setting 'two-port-y stx values 'y22))))
     #`(add-y-network-declaration #,@arguments)]
    [(_ . _)
     (raise-syntax-error
      'two-port-y
      "expected (two-port-y setting value ...)" stx)]))

(define-syntax (ideal-transformer stx)
  (syntax-parse stx
    [(_ setting ...)
     (define-values (values body)
       (parse-leading-settings
        'ideal-transformer stx #'(setting ...)
        '(name input output turns-ratio series-resistance)))
     (unless (null? body)
       (raise-syntax-error 'ideal-transformer
                           "unexpected expression after settings" stx
                           (car body)))
     (define arguments
       (append
        (optional-keyword values 'name #'#:name name-expression)
        (list #'#:input
              (port-reference-expression
               (require-setting 'ideal-transformer stx values 'input))
              #'#:output
              (port-reference-expression
               (require-setting 'ideal-transformer stx values 'output))
              #'#:turns-ratio
              (require-setting 'ideal-transformer stx values 'turns-ratio))
        (optional-keyword values 'series-resistance #'#:series-resistance)))
     #`(add-ideal-transformer-declaration #,@arguments)]
    [(_ . _)
     (raise-syntax-error
      'ideal-transformer
      "expected (ideal-transformer setting value ...)" stx)]))

(define-syntax (coax stx)
  (syntax-parse stx
    [(_ item ...)
     (define-values (values body)
       (parse-leading-settings
        'coax stx #'(item ...)
        '(type name output impedance velocity-factor diameter color input-gap
               input-direction feed)))
     (when (null? body)
       (raise-syntax-error 'coax "coax requires a shield-route body" stx))
     ;; The outermost coax normally supplies the generated input excitation.
     ;; A passive section uses `feed none` and is driven by an upstream line.
     (define feed?
       (if (hash-has-key? values 'feed)
           (let ([value (hash-ref values 'feed)])
             (literal value '(input none) 'coax stx
                      "feed must be input or none")
             (not (eq? (syntax-e value) 'none)))
           #t))
     (unless (or (hash-has-key? values 'velocity-factor)
                 (hash-has-key? values 'type))
       (raise-syntax-error
        'coax "velocity-factor is required unless a coax type is specified" stx))
     (define profile
       (if (hash-has-key? values 'type)
           (coax-type-expression (hash-ref values 'type) 'coax stx)
           #'#f))
     (define (profile-value accessor fallback)
       #`(if profile (#,accessor profile) #,fallback))
     (define arguments
       (append
        (optional-keyword values 'name #'#:name name-expression)
        (optional-keyword values 'output #'#:output port-reference-expression)
        (list
              #'#:impedance
              (if (hash-has-key? values 'impedance)
                  (hash-ref values 'impedance)
                  (profile-value #'coax-spec-impedance #'50))
              #'#:velocity-factor
              (if (hash-has-key? values 'velocity-factor)
                  (hash-ref values 'velocity-factor)
                  (profile-value #'coax-spec-velocity-factor #'(error 'coax "unreachable")))
              #'#:diameter
              (if (hash-has-key? values 'diameter)
                  (hash-ref values 'diameter)
                  (profile-value #'coax-spec-diameter #'(current-wire-diameter)))
              #'#:color
              (if (hash-has-key? values 'color)
                  (hash-ref values 'color)
                  (profile-value #'coax-spec-color #'"purple"))
              #'#:input-gap
              (if (hash-has-key? values 'input-gap)
                  (hash-ref values 'input-gap)
                  (profile-value #'coax-spec-input-gap #'centimeter))
              #'#:feed? (if feed? #'#t #'#f))
        (if (hash-has-key? values 'input-direction)
            (list #'#:input-direction
                  (literal-direction (hash-ref values 'input-direction) 'coax stx))
            (list #'#:input-direction #''up))))
     #`(let ([profile #,profile])
         (call-with-coax-declaration (lambda () #,@body) #,@arguments))]
    [(_ . _)
     (raise-syntax-error
      'coax
      "expected (coax setting value ... body ...)" stx)]))
