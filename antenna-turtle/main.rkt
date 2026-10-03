#lang racket

(require "private/core.rkt"
         "private/export-nec2c.rkt"
         "private/export-mmana.rkt"
         "private/export-matlab.rkt"
         "private/export-matlab-loft.rkt"
         (planet jphelps/loop:1:25)
         (for-syntax racket/base
                     racket/list
                     racket/syntax
                     syntax/parse))

(provide
 (except-out (all-from-out racket) #%module-begin)
 (rename-out [antenna-module-begin #%module-begin])
 (all-from-out (planet jphelps/loop:1:25))
 (except-out (all-from-out "private/core.rkt")
             move-local move-vector-local spread-local
             call-with-pen call-with-scale call-with-push)
 turn
 move
 spread
 with-pen
 with-scale
 with-push
 export-nec2c
 export-mmana
 export-matlab
 export-matlab-loft)

(define-syntax (antenna-module-begin stx)
  (syntax-case stx ()
    [(_ form ...)
     #'(#%plain-module-begin
        (reset-model!)
        form ...
        (validate-model!))]))

;; Direction words are contextual syntax keywords. Matching by datum is
;; deliberate: a model may bind an ordinary variable named left, right, up,
;; down, forward, or back without changing the meaning of these forms.
(define-syntax (turn stx)
  (syntax-parse stx
    [(_ (~datum left) degrees:expr)
     #'(turn-z degrees)]
    [(_ (~datum right) degrees:expr)
     #'(turn-z (- degrees))]
    [(_ (~datum up) degrees:expr)
     #'(turn-y (- degrees))]
    [(_ (~datum down) degrees:expr)
     #'(turn-y degrees)]
    [(_ direction degrees)
     (raise-syntax-error
      'turn
      "expected (turn left|right|up|down degrees)"
      stx
      #'direction)]))

(begin-for-syntax
  (define (move-direction-components direction whole-form)
    (case (syntax-e direction)
      [(forward) '(1 0 0)]
      [(back)    '(-1 0 0)]
      [(left)    '(0 1 0)]
      [(right)   '(0 -1 0)]
      [(up)      '(0 0 1)]
      [(down)    '(0 0 -1)]
      [else
       (raise-syntax-error
        'move
        "expected a direction: forward, back, left, right, up, or down"
        whole-form
        direction)]))

  (define (move-axis-expression components temporaries axis)
    (define terms
      (filter
       values
       (for/list ([component (in-list components)]
                  [temporary (in-list temporaries)])
         (define coefficient (list-ref component axis))
         (and (not (zero? coefficient))
              (if (= coefficient 1)
                  temporary
                  #`(- #,temporary))))))
    (cond
      [(null? terms) #'0]
      [(null? (cdr terms)) (car terms)]
      [else #`(+ #,@terms)])))

(define-syntax (move stx)
  (syntax-parse stx
    [(_ (~seq direction:id distance:expr) ...+)
     (define directions (syntax->list #'(direction ...)))
     (define distances (syntax->list #'(distance ...)))
     (define components
       (for/list ([direction (in-list directions)])
         (move-direction-components direction stx)))
     (define temporaries (generate-temporaries distances))
     (define bindings
       (for/list ([temporary (in-list temporaries)]
                  [distance (in-list distances)])
         #`[#,temporary #,distance]))
     (define x-expression
       (move-axis-expression components temporaries 0))
     (define y-expression
       (move-axis-expression components temporaries 1))
     (define z-expression
       (move-axis-expression components temporaries 2))
     #`(let* (#,@bindings)
         (move-vector-local #,x-expression #,y-expression #,z-expression))]
    [(_ . _)
     (raise-syntax-error
      'move
      (string-append
       "expected one or more direction/distance pairs, for example "
       "(move forward 10 up 1)")
      stx)]))

(define-syntax (spread stx)
  (syntax-parse stx
    [(_ (~datum forward) distance:expr)
     #'(spread-local 1 0 0 distance)]
    [(_ (~datum back) distance:expr)
     #'(spread-local -1 0 0 distance)]
    [(_ (~datum left) distance:expr)
     #'(spread-local 0 1 0 distance)]
    [(_ (~datum right) distance:expr)
     #'(spread-local 0 -1 0 distance)]
    [(_ (~datum up) distance:expr)
     #'(spread-local 0 0 1 distance)]
    [(_ (~datum down) distance:expr)
     #'(spread-local 0 0 -1 distance)]
    [(_ direction distance)
     (raise-syntax-error
      'spread
      "expected (spread forward|back|left|right|up|down distance)"
      stx
      #'direction)]))

(define-syntax-rule (with-pen body ...)
  (call-with-pen (lambda () body ...)))

(define-syntax-rule (with-scale factor body ...)
  (call-with-scale factor (lambda () body ...)))

(define-syntax-rule (with-push body ...)
  (call-with-push (lambda () body ...)))
