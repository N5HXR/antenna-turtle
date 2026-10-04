#lang racket

(require "private/core.rkt"
         "private/export-nec2c.rkt"
         "private/export-mmana.rkt"
         "private/export-matlab.rkt"
         "private/export-matlab-loft.rkt"
         k-infix
         (planet jphelps/loop:1:25)
         (for-syntax racket/base
                     racket/list
                     racket/syntax
                     syntax/parse))

(provide
 (except-out (all-from-out racket) #%module-begin)
 (rename-out [antenna-module-begin #%module-begin])
 #%braces
 (all-from-out (planet jphelps/loop:1:25))
 (except-out (all-from-out "private/core.rkt")
             move-local move-vector-local spread-local
             call-with-wire call-with-scale call-from-here
             call-with-pen call-with-push)
 model
 turn
 move
 spread
 with-wire
 from-here
 ;; Compatibility forms retained for existing models.
 with-pen
 with-scale
 with-push
 export-nec2c
 export-mmana
 export-matlab
 export-matlab-loft)

;; The language reader tags {...} as (#%braces ...). Delegate those tokens to
;; k-infix while retaining the lexical context of identifiers inside the form.
(define-syntax-rule (#%braces token ...)
  ($ token ...))

(define-syntax (antenna-module-begin stx)
  (syntax-case stx ()
    [(_ form ...)
     #'(#%plain-module-begin
        (reset-model!)
        form ...
        (validate-model!))]))

(begin-for-syntax
  (define (syntax-pairs who stx description)
    (define items (cdr (syntax->list stx)))
    (when (or (null? items) (odd? (length items)))
      (raise-syntax-error who description stx))
    (for/list ([offset (in-range 0 (length items) 2)])
      (define key (list-ref items offset))
      (unless (identifier? key)
        (raise-syntax-error who "expected a contextual keyword" stx key))
      (cons key (list-ref items (add1 offset)))))

  (define (turn-direction-call direction degrees whole-form)
    (case (syntax-e direction)
      [(left)       #`(turn-z #,degrees)]
      [(right)      #`(turn-z (- #,degrees))]
      [(up)         #`(turn-y (- #,degrees))]
      [(down)       #`(turn-y #,degrees)]
      ;; Aircraft-style naming as viewed by the turtle looking forward:
      ;; roll-left lowers local +Y; roll-right raises it.
      [(roll-left)  #`(turn-x (- #,degrees))]
      [(roll-right) #`(turn-x #,degrees)]
      [else
       (raise-syntax-error
        'turn
        (string-append
         "expected left, right, up, down, roll-left, or roll-right")
        whole-form
        direction)]))

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

;; Direction words are contextual syntax keywords. Matching by datum is
;; deliberate: ordinary lexical bindings with these names remain legal.
(define-syntax (turn stx)
  (define pairs
    (syntax-pairs
     'turn stx
     (string-append
      "expected one or more direction/angle pairs, for example "
      "(turn left 90 roll-right 30)")))
  #`(begin
      #,@(for/list ([pair (in-list pairs)])
           (turn-direction-call (car pair) (cdr pair) stx))))

(define-syntax (move stx)
  (define pairs
    (syntax-pairs
     'move stx
     (string-append
      "expected direction/distance pairs and an optional feed/location pair, "
      "for example (move forward 10 up 1 feed 'center)")))
  (define values (map cdr pairs))
  (define temporaries (generate-temporaries values))
  (define movement-pairs
    (for/list ([pair (in-list pairs)]
               [temporary (in-list temporaries)]
               #:unless (eq? (syntax-e (car pair)) 'feed))
      (cons (move-direction-components (car pair) stx) temporary)))
  (when (null? movement-pairs)
    (raise-syntax-error 'move "expected at least one movement direction" stx))
  (define feed-temporaries
    (for/list ([pair (in-list pairs)]
               [temporary (in-list temporaries)]
               #:when (eq? (syntax-e (car pair)) 'feed))
      temporary))
  (when (> (length feed-temporaries) 1)
    (raise-syntax-error 'move "feed may be specified only once" stx))
  (define components (map car movement-pairs))
  (define distance-temporaries (map cdr movement-pairs))
  (define bindings
    (for/list ([temporary (in-list temporaries)]
               [value (in-list values)])
      #`[#,temporary #,value]))
  (define x-expression
    (move-axis-expression components distance-temporaries 0))
  (define y-expression
    (move-axis-expression components distance-temporaries 1))
  (define z-expression
    (move-axis-expression components distance-temporaries 2))
  #`(let* (#,@bindings)
      #,@(if (null? feed-temporaries)
             '()
             (list #`(feed #,(car feed-temporaries))))
      (move-vector-local #,x-expression #,y-expression #,z-expression)))

(define-syntax (spread stx)
  (syntax-parse stx
    [(_ direction:id distance:expr)
     (define component (move-direction-components #'direction stx))
     #`(spread-local #,@component distance)]
    [(_ direction:id distance:expr (~datum feed) location:expr)
     (define component (move-direction-components #'direction stx))
     #`(let* ([saved-distance distance]
              [saved-location location])
         (feed saved-location)
         (spread-local #,@component saved-distance))]
    [(_ . _)
     (raise-syntax-error
      'spread
      (string-append
       "expected (spread direction distance) or "
       "(spread direction distance feed location)")
      stx)]))

(define-syntax (model stx)
  (define pairs
    (if (null? (cdr (syntax->list stx)))
        '()
        (syntax-pairs
         'model stx
         (string-append
          "expected setting/value pairs using title, frequency, max-length, "
          "or wire-diameter"))))
  (define seen (make-hasheq))
  (define settings (make-hasheq))
  (for ([pair (in-list pairs)])
    (define key (syntax-e (car pair)))
    (unless (memq key '(title frequency max-length wire-diameter))
      (raise-syntax-error
       'model
       "expected title, frequency, max-length, or wire-diameter"
       stx
       (car pair)))
    (when (hash-ref seen key #f)
      (raise-syntax-error
       'model "setting may be specified only once" stx (car pair)))
    (hash-set! seen key #t)
    (hash-set! settings key (cdr pair)))
  ;; A model form is declarative rather than order-sensitive. Apply frequency
  ;; before max-length so the latter may use model-wavelength regardless of
  ;; the pair order written by the programmer.
  (define forms
    (filter
     values
     (for/list ([key '(title frequency max-length wire-diameter)])
       (define value (hash-ref settings key #f))
       (and value
            (case key
              [(title)         #`(model-title #,value)]
              [(frequency)     #`(model-frequency #,value)]
              [(max-length)    #`(maximum-segment-length #,value)]
              [(wire-diameter) #`(wire-diameter #,value)])))))
  #`(begin #,@forms))

(define-syntax-rule (with-wire body ...)
  (call-with-wire (lambda () body ...)))

(define-syntax-rule (from-here body ...)
  (call-from-here (lambda () body ...)))

(define-syntax-rule (with-pen body ...)
  (with-wire body ...))

(define-syntax-rule (with-scale factor body ...)
  (call-with-scale factor (lambda () body ...)))

(define-syntax-rule (with-push body ...)
  (from-here body ...))
