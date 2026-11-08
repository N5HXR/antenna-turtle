#lang racket/base

(require (only-in "core.rkt"
                  set-wire-coating!
                  call-with-wire-coating)
         (for-syntax racket/base racket/list syntax/parse))

(provide wire-coating with-wire-coating)

(begin-for-syntax
  (define (coating-settings who stx items body?)
    (define remaining (syntax->list items))
    (define settings (make-hasheq))
    (let loop ([rest remaining])
      (cond
        [(and (pair? rest)
              (identifier? (car rest))
              (memq (syntax-e (car rest)) '(material diameter)))
         (when (null? (cdr rest))
           (raise-syntax-error who "setting is missing its value" stx (car rest)))
         (define key (syntax-e (car rest)))
         (when (hash-has-key? settings key)
           (raise-syntax-error who "setting may be specified only once" stx (car rest)))
         (hash-set! settings key (cadr rest))
         (loop (cddr rest))]
        [else
         (for ([key '(material diameter)])
           (unless (hash-has-key? settings key)
             (raise-syntax-error who (format "~a is required" key) stx)))
         (when (and (not body?) (pair? rest))
           (raise-syntax-error who
                               "expected only material and diameter setting/value pairs"
                               stx (car rest)))
         (when (and body? (null? rest))
           (raise-syntax-error who "at least one body expression is required" stx))
         (values settings rest)]))))

(define-syntax (wire-coating stx)
  (syntax-parse stx
    [(_ item ...)
     (define-values (settings ignored)
       (coating-settings 'wire-coating stx #'(item ...) #f))
     #`(set-wire-coating! #,(hash-ref settings 'material)
                          #,(hash-ref settings 'diameter))]))

(define-syntax (with-wire-coating stx)
  (syntax-parse stx
    [(_ item ...)
     (define-values (settings body)
       (coating-settings 'with-wire-coating stx #'(item ...) #t))
     #`(call-with-wire-coating
        #,(hash-ref settings 'material)
        #,(hash-ref settings 'diameter)
        (lambda () #,@body))]))
