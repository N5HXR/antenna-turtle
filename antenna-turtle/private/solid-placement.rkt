#lang racket/base

(require racket/list
         (prefix-in m: manifold)
         "core.rkt")

(provide scale-transform
         solid-anchor-point
         point-values
         transform-vector
         transform-point)

(define (finite-real? value)
  (and (real? value) (rational? value)))

(define (scale-transform transform factor)
  (for/list ([row (in-list transform)])
    (append (map (lambda (value) (* factor value)) (take row 3))
            (list (fourth row)))))

(define anchor-axis
  (hash 'front   (cons 0 'maximum)
        'forward (cons 0 'maximum)
        'back    (cons 0 'minimum)
        'left    (cons 1 'maximum)
        'right   (cons 1 'minimum)
        'top     (cons 2 'maximum)
        'up      (cons 2 'maximum)
        'bottom  (cons 2 'minimum)
        'down    (cons 2 'minimum)))

(define (bounds-center minimum maximum)
  (map (lambda (low high) (/ (+ low high) 2)) minimum maximum))

(define (solid-anchor-point who geometry anchor)
  (define-values (minimum-point maximum-point) (m:solid-bounds geometry))
  (define minimum
    (list (m:point3-x minimum-point)
          (m:point3-y minimum-point)
          (m:point3-z minimum-point)))
  (define maximum
    (list (m:point3-x maximum-point)
          (m:point3-y maximum-point)
          (m:point3-z maximum-point)))
  (cond
    [(eq? anchor 'origin) '(0 0 0)]
    [(eq? anchor 'center) (bounds-center minimum maximum)]
    [(or (point3? anchor)
         (and (list? anchor) (= (length anchor) 3)
              (andmap finite-real? anchor))
         (and (vector? anchor) (= (vector-length anchor) 3)
              (andmap finite-real? (vector->list anchor))))
     (point-values who anchor 3)]
    [else
     (define directions (if (symbol? anchor) (list anchor) anchor))
     (unless (and (list? directions) (pair? directions)
                  (andmap symbol? directions))
       (raise-argument-error
        who
        "anchor direction, list of orthogonal directions, or local point"
        anchor))
     (define selected (make-hasheq))
     (for ([direction (in-list directions)])
       (define selection (hash-ref anchor-axis direction #f))
       (unless selection
         (raise-arguments-error who "unknown anchor direction"
                                "direction" direction))
       (define axis (car selection))
       (when (hash-has-key? selected axis)
         (raise-arguments-error
          who "anchor directions must select at most one face per axis"
          "anchor" anchor))
       (hash-set! selected axis (cdr selection)))
     (for/list ([axis (in-range 3)])
       (case (hash-ref selected axis 'center)
         [(minimum) (list-ref minimum axis)]
         [(maximum) (list-ref maximum axis)]
         [else (/ (+ (list-ref minimum axis) (list-ref maximum axis)) 2)]))]))

(define (point-values who value count)
  (define values
    (cond
      [(and (list? value) (= (length value) count)) value]
      [(and (vector? value) (= (vector-length value) count))
       (vector->list value)]
      [else
       (raise-argument-error
        who (format "~a-element list or vector" count) value)]))
  (for ([item (in-list values)])
    (unless (finite-real? item)
      (raise-argument-error who "finite real coordinates" value)))
  values)

(define (transform-vector matrix value)
  (define coordinates (point-values 'transform-vector value 3))
  (apply point3
         (for/list ([row (in-list matrix)])
           (for/sum ([coefficient (in-list (take row 3))]
                     [coordinate (in-list coordinates)])
             (* coefficient coordinate)))))

(define (transform-point matrix value)
  (define direction (transform-vector matrix value))
  (point3 (+ (point3-x direction) (list-ref (first matrix) 3))
          (+ (point3-y direction) (list-ref (second matrix) 3))
          (+ (point3-z direction) (list-ref (third matrix) 3))))
