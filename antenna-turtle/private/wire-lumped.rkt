#lang racket/base

(require racket/list
         racket/math
         "core.rkt")

(provide
 (struct-out wire-lumped-element)
 current-solid-lumped-element-handler
 add-lumped-element-declaration
 model-wire-lumped-elements
 clear-wire-lumped-elements)

;; A backend-neutral two-terminal declaration.  NEC resolves the center onto a
;; degree-two wire vertex and synthesizes a dedicated loaded segment; OpenEMS
;; continues to use the spatial lumped-component registered by solid-core.
(struct wire-lumped-element
  (name resistance inductance capacitance topology center direction gap
        declaration-index)
  #:transparent)

(define current-wire-lumped-elements (make-parameter '()))
(define current-solid-lumped-element-handler (make-parameter #f))

(define (model-wire-lumped-elements)
  (current-wire-lumped-elements))

(define (clear-wire-lumped-elements)
  (current-wire-lumped-elements '())
  (void))

(register-model-reset-hook! clear-wire-lumped-elements)
(register-wire-clear-hook! clear-wire-lumped-elements)

(define (finite-real? value)
  (and (real? value) (rational? value)))

(define (positive-real who value description)
  (unless (and (finite-real? value) (positive? value))
    (raise-arguments-error who
                           (format "~a must be a positive finite real" description)
                           description value))
  value)

(define local-directions
  (hash 'forward '(1 0 0) 'forwards '(1 0 0)
        'back '(-1 0 0) 'backward '(-1 0 0) 'backwards '(-1 0 0)
        'left '(0 1 0) 'right '(0 -1 0)
        'up '(0 0 1) 'down '(0 0 -1)))

(define (transform-direction transform coordinates)
  (apply point3
         (for/list ([row (in-list transform)])
           (for/sum ([coefficient (in-list (take row 3))]
                     [coordinate (in-list coordinates)])
             (* coefficient coordinate)))))

(define (reflect-vector vector normal)
  (define normal-length-squared
    (+ (sqr (point3-x normal))
       (sqr (point3-y normal))
       (sqr (point3-z normal))))
  (define projection-factor
    (/ (* 2 (+ (* (point3-x vector) (point3-x normal))
               (* (point3-y vector) (point3-y normal))
               (* (point3-z vector) (point3-z normal))))
       normal-length-squared))
  (point3 (- (point3-x vector) (* projection-factor (point3-x normal)))
          (- (point3-y vector) (* projection-factor (point3-y normal)))
          (- (point3-z vector) (* projection-factor (point3-z normal)))))

(define (reflect-point point context)
  (define anchor (reflection-context-anchor context))
  (define offset
    (point3 (- (point3-x point) (point3-x anchor))
            (- (point3-y point) (point3-y anchor))
            (- (point3-z point) (point3-z anchor))))
  (define reflected
    (reflect-vector offset (reflection-context-normal context)))
  (point3 (+ (point3-x anchor) (point3-x reflected))
          (+ (point3-y anchor) (point3-y reflected))
          (+ (point3-z anchor) (point3-z reflected))))

(define (same-point? first second)
  (and (= (point3-x first) (point3-x second))
       (= (point3-y first) (point3-y second))
       (= (point3-z first) (point3-z second))))

(define (fresh-reflected-name name declarations)
  (define base (format "~a-reflected" name))
  (let loop ([suffix #f])
    (define candidate
      (string->symbol (if suffix (format "~a-~a" base suffix) base)))
    (if (for/or ([element (in-list declarations)])
          (equal? candidate (wire-lumped-element-name element)))
        (loop (if suffix (add1 suffix) 2))
        candidate)))

(define (add-lumped-element-declaration
         direction
         #:name [requested-name #f]
         #:resistance [resistance #f]
         #:inductance [inductance #f]
         #:capacitance [capacitance #f]
         #:topology [topology #f]
         #:caps [caps #t]
         #:gap gap
         #:width [width #f]
         #:depth [depth #f]
         #:anchor [anchor 'center]
         #:priority [priority #f]
         #:precedence [precedence #f])
  (define who 'lumped-element)
  (define local-direction (hash-ref local-directions direction #f))
  (unless local-direction
    (raise-argument-error who "turtle direction" direction))
  (define electrical-values (filter values (list resistance inductance capacitance)))
  (when (null? electrical-values)
    (raise-arguments-error who "at least one electrical value is required"))
  (for ([value (in-list electrical-values)])
    (positive-real who value "electrical value"))
  (unless (or (not topology) (memq topology '(series parallel)))
    (raise-argument-error who "(or/c #f 'series 'parallel)" topology))
  (when (and (> (length electrical-values) 1) (not topology))
    (raise-arguments-error
     who "topology is required when multiple electrical values are present"))
  (unless (boolean? caps)
    (raise-argument-error who "boolean?" caps))
  (positive-real who gap "gap")
  (unless (memq anchor '(start center end))
    (raise-argument-error who "(or/c 'start 'center 'end)" anchor))
  (unless (or (and width depth) (and (not width) (not depth)))
    (raise-arguments-error who "supply both width and depth, or neither"))
  (when width
    (positive-real who width "width")
    (positive-real who depth "depth"))
  (define wire-intended? (or (current-wire-active?) (not width)))
  (when (and wire-intended? (not (eq? anchor 'center)))
    (raise-arguments-error
     who "NEC wire lumped elements currently require anchor center"
     "anchor" anchor))
  (define transform (current-turtle-affine-transform who))
  (define scale-factor (current-geometry-scale))
  (define world-direction (transform-direction transform local-direction))
  (define origin (current-position))
  (define effective-gap (* scale-factor gap))
  (define declarations (current-wire-lumped-elements))
  (define name
    (or requested-name (string->symbol (format "element-~a" (add1 (length declarations))))))
  (when (and wire-intended?
             (for/or ([element (in-list declarations)])
               (equal? name (wire-lumped-element-name element))))
    (raise-arguments-error who "wire lumped-element names must be unique" "name" name))
  (define marker
    (and wire-intended?
         (wire-lumped-element
          name resistance inductance capacitance (or topology 'parallel)
          origin world-direction effective-gap (add1 (length declarations)))))
  (when marker
    (define reflection (current-reflection-context))
    (define reflected-center (and reflection (reflect-point origin reflection)))
    (define reflected-marker
      (and reflection
           (not (same-point? origin reflected-center))
           (wire-lumped-element
            (fresh-reflected-name name (append declarations (list marker)))
            resistance inductance capacitance (or topology 'parallel)
            reflected-center
            (reflect-vector world-direction
                            (reflection-context-normal reflection))
            effective-gap (+ 2 (length declarations)))))
    (current-wire-lumped-elements
     (append declarations (list marker)
             (if reflected-marker (list reflected-marker) '()))))
  (define solid-handler (current-solid-lumped-element-handler))
  (define solid-component
    (and width solid-handler
         (solid-handler
          direction
          #:name requested-name
          #:resistance resistance #:inductance inductance #:capacitance capacitance
          #:topology topology #:caps caps #:gap gap
          #:width width #:depth depth #:anchor anchor
          #:priority priority #:precedence precedence)))
  (or solid-component marker))
