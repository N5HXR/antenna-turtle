#lang racket

(require "solid-primitives.rkt"
         "solid-trace.rkt"
         (for-syntax racket/base syntax/parse))

(provide with-traces)

(begin-for-syntax
  (define (name-expression value)
    (if (identifier? value) #`'#,(syntax-e value) value))
  (define (optional-keyword settings key keyword [convert values])
    (if (hash-has-key? settings key)
        (list keyword (convert (hash-ref settings key)))
        '())))

(define-syntax (with-traces stx)
  (syntax-parse stx
    [(_ width:expr item ...)
     (define items (syntax->list #'(item ...)))
     (define allowed '(name material thickness priority precedence join miter-limit))
     (define settings (make-hasheq))
     (define body
       (let loop ([remaining items])
         (cond
           [(and (pair? remaining)
                 (identifier? (car remaining))
                 (memq (syntax-e (car remaining)) allowed))
            (when (null? (cdr remaining))
              (raise-syntax-error 'with-traces
                                  "setting is missing its value" stx
                                  (car remaining)))
            (define key (syntax-e (car remaining)))
            (when (hash-has-key? settings key)
              (raise-syntax-error 'with-traces
                                  "setting may be specified only once" stx
                                  (car remaining)))
            (hash-set! settings key (cadr remaining))
            (loop (cddr remaining))]
           [else remaining])))
     (when (null? body)
       (raise-syntax-error 'with-traces
                           "at least one turtle expression is required" stx))
     (when (and (hash-has-key? settings 'priority)
                (hash-has-key? settings 'precedence))
       (raise-syntax-error 'with-traces
                           "use either priority or precedence, not both" stx))
     (define join
       (if (hash-has-key? settings 'join)
           (let ([value (hash-ref settings 'join)])
             (unless (and (identifier? value)
                          (memq (syntax-e value) '(miter bevel)))
               (raise-syntax-error 'with-traces
                                   "join must be miter or bevel" stx value))
             #`'#,(syntax-e value))
           #''miter))
     (with-syntax ([(body-form ...) body])
       #`(call-with-traces
          width (lambda () body-form ...)
          #,@(optional-keyword settings 'name #'#:name name-expression)
          #:material #,(hash-ref settings 'material #'(current-solid-material))
          #,@(optional-keyword settings 'thickness #'#:thickness)
          #,@(append (optional-keyword settings 'priority #'#:precedence)
                     (optional-keyword settings 'precedence #'#:precedence))
          #:join #,join
          #,@(optional-keyword settings 'miter-limit #'#:miter-limit)))]
    [(_ . _)
     (raise-syntax-error
      'with-traces
      "expected (with-traces WIDTH setting value ... body ...)" stx)]))
