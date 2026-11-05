#lang racket/base

(require racket/list
         racket/math
         "nec2c.rkt")

(provide (struct-out near-field-flow-field)
         (struct-out near-field-flow-state)
         make-near-field-flow-field
         near-field-flow-sample
         near-field-flow-seed-weights
         near-field-plane-point)

(define vacuum-permittivity 8.8541878128e-12)
(define vacuum-permeability (* 4 pi 1e-7))

(struct near-field-flow-field
  (section frequency-mhz u-values v-values samples u-count v-count)
  #:transparent)

(struct near-field-flow-state
  (velocity poynting electric-energy magnetic-energy)
  #:transparent)

(define (make-near-field-flow-field section frequency-mhz)
  (unless (nec2c-near-field-section? section)
    (raise-argument-error 'make-near-field-flow-field
                          "nec2c-near-field-section?" section))
  (unless (and (real? frequency-mhz) (positive? frequency-mhz))
    (raise-argument-error 'make-near-field-flow-field
                          "positive-real?" frequency-mhz))
  (define u-values (list->vector (nec2c-near-field-section-u-values section)))
  (define v-values (list->vector (nec2c-near-field-section-v-values section)))
  (define samples (list->vector (nec2c-near-field-section-samples section)))
  (unless (and (>= (vector-length u-values) 2)
               (>= (vector-length v-values) 2)
               (= (vector-length samples)
                  (* (vector-length u-values) (vector-length v-values))))
    (raise-arguments-error
     'make-near-field-flow-field
     "near-field section must contain a rectangular grid of at least 2 × 2 samples"
     "u samples" (vector-length u-values)
     "v samples" (vector-length v-values)
     "field samples" (vector-length samples)))
  (near-field-flow-field section frequency-mhz u-values v-values samples
                         (vector-length u-values) (vector-length v-values)))

(define (vector3-map procedure a [b #f])
  (if b
      (for/list ([x (in-list a)] [y (in-list b)]) (procedure x y))
      (map procedure a)))

(define (vector3+ a b) (vector3-map + a b))
(define (vector3- a b) (vector3-map - a b))
(define (vector3-scale a scale) (vector3-map (lambda (x) (* x scale)) a))
(define (vector3-dot a b) (apply + (vector3-map * a b)))
(define (vector3-cross a b)
  (list (- (* (second a) (third b)) (* (third a) (second b)))
        (- (* (third a) (first b)) (* (first a) (third b)))
        (- (* (first a) (second b)) (* (second a) (first b)))))

(define (interval-at values coordinate)
  (define count (vector-length values))
  (define minimum (vector-ref values 0))
  (define maximum (vector-ref values (sub1 count)))
  (cond
    [(or (< coordinate minimum) (> coordinate maximum)) #f]
    [(= coordinate maximum) (cons (- count 2) 1.0)]
    [else
     (let loop ([low 0] [high (sub1 count)])
       (define middle (quotient (+ low high) 2))
       (define lower (vector-ref values middle))
       (define upper (vector-ref values (add1 middle)))
       (cond
         [(< coordinate lower) (loop low middle)]
         [(>= coordinate upper) (loop (add1 middle) high)]
         [else (cons middle (/ (- coordinate lower) (- upper lower)))]))]))

(define (sample-field field u-index v-index accessor)
  (accessor
   (vector-ref (near-field-flow-field-samples field)
               (+ u-index (* v-index (near-field-flow-field-u-count field))))))

(define (lerp a b fraction) (+ a (* fraction (- b a))))

(define (bilinear-vector field u-index v-index u-fraction v-fraction accessor)
  (define a (sample-field field u-index v-index accessor))
  (define b (sample-field field (add1 u-index) v-index accessor))
  (define c (sample-field field u-index (add1 v-index) accessor))
  (define d (sample-field field (add1 u-index) (add1 v-index) accessor))
  (for/list ([av (in-list a)] [bv (in-list b)]
             [cv (in-list c)] [dv (in-list d)])
    (lerp (lerp av bv u-fraction)
          (lerp cv dv u-fraction)
          v-fraction)))

(define (instantaneous phasor phase)
  (define cosine (cos phase))
  (define sine (sin phase))
  (for/list ([value (in-list phasor)])
    (- (* (real-part value) cosine) (* (imag-part value) sine))))

(define (average-poynting electric magnetic)
  (vector3-scale
   (vector3-map real-part
                (vector3-cross electric (vector3-map conjugate magnetic)))
   0.5))

(define (phasor-energy phasor coefficient)
  (* 0.25 coefficient
     (for/sum ([value (in-list phasor)])
       (+ (sqr (real-part value)) (sqr (imag-part value))))))

(define (instantaneous-energy vector coefficient)
  (* 0.5 coefficient (vector3-dot vector vector)))

(define (near-field-flow-sample field u v phase [mode 'reactive])
  (unless (memq mode '(instantaneous reactive average))
    (raise-argument-error 'near-field-flow-sample
                          "(or/c 'instantaneous 'reactive 'average)" mode))
  (define u-location (interval-at (near-field-flow-field-u-values field) u))
  (define v-location (interval-at (near-field-flow-field-v-values field) v))
  (and u-location v-location
       (let* ([u-index (car u-location)] [u-fraction (cdr u-location)]
              [v-index (car v-location)] [v-fraction (cdr v-location)]
              [electric
               (bilinear-vector field u-index v-index u-fraction v-fraction
                                nec2c-near-field-sample-electric)]
              [magnetic
               (bilinear-vector field u-index v-index u-fraction v-fraction
                                nec2c-near-field-sample-magnetic)]
              [average (average-poynting electric magnetic)]
              [instant-electric (instantaneous electric phase)]
              [instant-magnetic (instantaneous magnetic phase)]
              [instant-flow (vector3-cross instant-electric instant-magnetic)]
              [poynting
               (case mode
                 [(instantaneous) instant-flow]
                 [(reactive) (vector3- instant-flow average)]
                 [(average) average])]
              [electric-energy
               (if (eq? mode 'average)
                   (phasor-energy electric vacuum-permittivity)
                   (instantaneous-energy instant-electric vacuum-permittivity))]
              [magnetic-energy
               (if (eq? mode 'average)
                   (phasor-energy magnetic vacuum-permeability)
                   (instantaneous-energy instant-magnetic vacuum-permeability))]
              [energy (+ electric-energy magnetic-energy)]
              [velocity
               (if (> energy 1e-30)
                   (vector3-scale poynting (/ energy))
                   '(0.0 0.0 0.0))])
         (near-field-flow-state velocity poynting
                                electric-energy magnetic-energy))))

(define (near-field-flow-seed-weights field)
  (for/list ([sample (in-vector (near-field-flow-field-samples field))])
    (define electric
      (phasor-energy (nec2c-near-field-sample-electric sample)
                     vacuum-permittivity))
    (define magnetic
      (phasor-energy (nec2c-near-field-sample-magnetic sample)
                     vacuum-permeability))
    (sqrt (max 0 (+ electric magnetic)))))

(define (near-field-plane-point section u v [normal-offset 0.0])
  (define coordinates (make-hasheq '((x . 0.0) (y . 0.0) (z . 0.0))))
  (hash-set! coordinates (nec2c-near-field-section-u-axis section) u)
  (hash-set! coordinates (nec2c-near-field-section-v-axis section) v)
  (hash-set! coordinates (nec2c-near-field-section-normal-axis section)
             (+ (nec2c-near-field-section-position section) normal-offset))
  (list (hash-ref coordinates 'x)
        (hash-ref coordinates 'y)
        (hash-ref coordinates 'z)))

(module+ test
  (require rackunit)
  (define samples
    (for*/list ([v '(-1.0 1.0)] [u '(-1.0 1.0)])
      (nec2c-near-field-sample
       u v 0.0 '(1.0+0.0i 0.0+0.0i 0.0+0.0i)
       '(0.0+0.0i 0.0026544187+0.0i 0.0+0.0i))))
  (define section
    (nec2c-near-field-section 'xy 'z 0.0 'x 'y
                              '(-1.0 1.0) '(-1.0 1.0)
                              samples '(electric magnetic)))
  (define field (make-near-field-flow-field section 100.0))
  (define state (near-field-flow-sample field 0.0 0.0 0.0 'instantaneous))
  (check-true (near-field-flow-state? state))
  (check-true (> (third (near-field-flow-state-poynting state)) 0))
  (check-false (near-field-flow-sample field 2.0 0.0 0.0 'instantaneous))
  (check-equal? (near-field-plane-point section 2.0 3.0) '(2.0 3.0 0.0)))
