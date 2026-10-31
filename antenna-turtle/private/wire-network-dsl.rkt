#lang racket/base

(require "wire-network.rkt"
         (for-syntax racket/base racket/list syntax/parse))

(provide wire-port transmission-line two-port-y coax)

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
        (list #'#:input (require-setting 'transmission-line stx values 'input)
              #'#:output (require-setting 'transmission-line stx values 'output))
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
        (list #'#:input (require-setting 'two-port-y stx values 'input)
              #'#:output (require-setting 'two-port-y stx values 'output)
              #'#:y11 (require-setting 'two-port-y stx values 'y11)
              #'#:y12 (require-setting 'two-port-y stx values 'y12)
              #'#:y22 (require-setting 'two-port-y stx values 'y22))))
     #`(add-y-network-declaration #,@arguments)]
    [(_ . _)
     (raise-syntax-error
      'two-port-y
      "expected (two-port-y setting value ...)" stx)]))

(define-syntax (coax stx)
  (syntax-parse stx
    [(_ item ...)
     (define-values (values body)
       (parse-leading-settings
        'coax stx #'(item ...)
        '(name output impedance velocity-factor diameter color input-gap
               input-direction feed)))
     (when (null? body)
       (raise-syntax-error 'coax "coax requires a shield-route body" stx))
     (when (hash-has-key? values 'feed)
       (literal (hash-ref values 'feed) '(input) 'coax stx
                "revision 1 supports only feed input"))
     (define arguments
       (append
        (list #'#:name
              (name-expression (require-setting 'coax stx values 'name))
              #'#:output (require-setting 'coax stx values 'output))
        (optional-keyword values 'impedance #'#:impedance)
        (optional-keyword values 'color #'#:color)
        (list #'#:velocity-factor
              (require-setting 'coax stx values 'velocity-factor)
              #'#:diameter (require-setting 'coax stx values 'diameter)
              #'#:input-gap (require-setting 'coax stx values 'input-gap))
        (if (hash-has-key? values 'input-direction)
            (list #'#:input-direction
                  (literal-direction (hash-ref values 'input-direction) 'coax stx))
            '())))
     #`(call-with-coax-declaration (lambda () #,@body) #,@arguments)]
    [(_ . _)
     (raise-syntax-error
      'coax
      "expected (coax setting value ... body ...)" stx)]))
