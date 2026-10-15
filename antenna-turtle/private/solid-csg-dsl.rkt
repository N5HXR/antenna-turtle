#lang racket

(require (only-in "core.rkt" [scale turtle-scale])
         (only-in "material.rkt" pec)
         "solid-csg.rkt"
         "solid-primitives.rkt"
         (for-syntax racket/base racket/list syntax/parse))

(provide with-body union difference intersect hull scale)

(begin-for-syntax
  (define (name-expression value)
    (if (identifier? value) #`'#,(syntax-e value) value))
  (define (optional-keyword settings key keyword)
    (if (hash-has-key? settings key)
        (list keyword (hash-ref settings key))
        '())))

(define-syntax (with-body stx)
  (syntax-parse stx
    [(_ old-name:id item ...)
     #:when (not (memq (syntax-e #'old-name)
                       '(name material priority precedence anchor metal-thickness form)))
     (raise-syntax-error
      'with-body
      "positional names are not supported; use name VALUE"
      stx #'old-name)]
    [(_ item ...)
     (define allowed '(name material priority precedence anchor metal-thickness form))
     (define all-items (syntax->list #'(item ...)))
     (define values (make-hasheq))
     (let loop ([remaining all-items])
       (cond
         [(and (pair? remaining)
               (identifier? (car remaining))
               (memq (syntax-e (car remaining)) allowed))
          (when (null? (cdr remaining))
            (raise-syntax-error 'with-body "setting is missing its value" stx
                                (car remaining)))
          (define key (syntax-e (car remaining)))
          (when (hash-has-key? values key)
            (raise-syntax-error 'with-body "setting may be specified only once"
                                stx (car remaining)))
          (hash-set! values key (cadr remaining))
          (loop (cddr remaining))]
         [else
          (when (null? remaining)
            (raise-syntax-error 'with-body
                                "at least one solid expression is required" stx))
          (define explicit-material? (hash-has-key? values 'material))
          (define form
            (if (hash-has-key? values 'form)
                (name-expression (hash-ref values 'form))
                #''solid))
          (define material
            (and explicit-material? (hash-ref values 'material)))
          (define anchor
            (if (hash-has-key? values 'anchor)
                (let ([value (hash-ref values 'anchor)])
                  (if (identifier? value) #`'#,(syntax-e value) value))
                #''center))
          (with-syntax ([(body-form ...) remaining])
            #`(let* ([body-form-kind #,form]
                     [body-material
                      #,(if explicit-material?
                            material
                            #'(if (eq? body-form-kind 'surface)
                                  pec
                                  (current-solid-material)))])
                (add-csg-body
                 #,(if (hash-has-key? values 'name)
                       (name-expression (hash-ref values 'name))
                       #'#f)
                 body-material
                 (call-with-csg-body (lambda () body-form ...))
                 #,@(optional-keyword values 'priority #'#:priority)
                 #,@(optional-keyword values 'precedence #'#:precedence)
                 #,@(optional-keyword values 'metal-thickness #'#:metal-thickness)
                 #:anchor #,anchor
                 #:form body-form-kind
                 #:material-source
                 #,(if explicit-material?
                       #''explicit-or-context
                       #'(if (eq? body-form-kind 'surface)
                             'forced-by-surface-form
                             'explicit-or-context)))))]))]
    [(_ . _)
     (raise-syntax-error
      'with-body
      "expected (with-body [name value] setting value ... body ...)" stx)]))

(define-syntax-rule (union body ...)
  (call-with-csg-operation 'union (lambda () body ...)))

(define-syntax-rule (difference body ...)
  (call-with-csg-operation 'difference (lambda () body ...)))

(define-syntax-rule (intersect body ...)
  (call-with-csg-operation 'intersect (lambda () body ...)))

(define-syntax-rule (hull body ...)
  (call-with-csg-operation 'hull (lambda () body ...)))

;; Preserve the ordinary one-argument scale procedure (including first-class
;; references to it) while adding a scoped CSG expression form.
(define-syntax (scale stx)
  (syntax-parse stx
    [name:id #'turtle-scale]
    [(_ factor:expr) #'(turtle-scale factor)]
    [(_ factor:expr body ...+)
     #'(call-with-csg-scale factor (lambda () body ...))]))
