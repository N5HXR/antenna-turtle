#lang racket/base

(provide
 (struct-out material-loss)
 (struct-out broadband-loss-range)
 (struct-out relaxation-pole)
 (struct-out em-material)
 pec
 dielectric
 make-dielectric
 make-narrow-loss
 make-broad-loss
 make-relaxation-loss
 model-dielectric
 material-loss-tangent
 conductor
 make-conductor
 conducting-sheet-material
 material-default-precedence)

;; A dielectric loss may be expressed directly as conductivity, or as a loss
;; tangent whose conductivity is derived by a backend for one reference
;; frequency.  'model means the model's declared center frequency.
(struct material-loss (kind value reference-frequency) #:transparent)

;; A broadband fit can either have explicit corner frequencies or defer them
;; to the model frequency.  Keeping the latter symbolic is important: geometry
;; can be reused with more than one simulation profile.
(struct broadband-loss-range
  (lower-frequency upper-frequency reference-frequency model-factor)
  #:transparent)

(struct relaxation-pole (delta-epsilon relaxation-time) #:transparent)

(struct em-material
  (name kind relative-permittivity relative-permeability
        electric-conductivity magnetic-conductivity thickness loss-spec)
  #:transparent)

(define pec (em-material 'pec 'pec #f #f #f #f 0 #f))

(define (finite-real? value)
  (and (real? value) (rational? value)))

(define (positive-real who value description)
  (unless (and (finite-real? value) (positive? value))
    (raise-arguments-error who
                           (format "~a must be a positive finite real" description)
                           description value))
  value)

(define (nonnegative-real who value description)
  (unless (and (finite-real? value) (>= value 0))
    (raise-arguments-error who
                           (format "~a must be a nonnegative finite real" description)
                           description value))
  value)

(define (material-name who value)
  (unless (or (symbol? value)
              (and (string? value) (not (string=? value ""))))
    (raise-argument-error who "(or/c symbol? non-empty-string?)" value))
  value)

(define (loss-reference who value)
  (unless (or (eq? value 'model)
              (and (finite-real? value) (positive? value)))
    (raise-argument-error who "(or/c 'model positive-real?)" value))
  value)

(define (make-narrow-loss tangent [reference-frequency 'model])
  (positive-real 'make-narrow-loss tangent "loss tangent")
  (loss-reference 'make-narrow-loss reference-frequency)
  (material-loss 'narrow tangent reference-frequency))

(define (make-broad-loss tangent lower-frequency upper-frequency
                         #:reference-frequency [reference-frequency 'model])
  (positive-real 'make-broad-loss tangent "loss tangent")
  (positive-real 'make-broad-loss lower-frequency "lower frequency")
  (positive-real 'make-broad-loss upper-frequency "upper frequency")
  (unless (< lower-frequency upper-frequency)
    (raise-arguments-error
     'make-broad-loss "lower frequency must be less than upper frequency"
     "lower frequency" lower-frequency "upper frequency" upper-frequency))
  (loss-reference 'make-broad-loss reference-frequency)
  (material-loss
   'broad tangent
   (broadband-loss-range
    lower-frequency upper-frequency reference-frequency #f)))

(define (make-model-broad-loss tangent factor)
  (positive-real 'model-dielectric tangent "loss tangent")
  (unless (and (finite-real? factor) (> factor 1))
    (raise-arguments-error
     'model-dielectric "factor must be a finite real greater than 1"
     "factor" factor))
  (material-loss 'broad tangent
                 (broadband-loss-range #f #f 'model factor)))

(define (make-relaxation-loss poles)
  (unless (and (list? poles) (pair? poles))
    (raise-argument-error 'make-relaxation-loss
                          "non-empty-list?" poles))
  (define normalized
    (for/list ([pole (in-list poles)])
      (define-values (delta-epsilon relaxation-time)
        (cond
          [(relaxation-pole? pole)
           (values (relaxation-pole-delta-epsilon pole)
                   (relaxation-pole-relaxation-time pole))]
          [(and (list? pole) (= (length pole) 2))
           (values (car pole) (cadr pole))]
          [else
           (raise-argument-error
            'make-relaxation-loss
            "(listof (or/c relaxation-pole? (list/c positive-real? positive-real?)))"
            poles)]))
      (positive-real 'make-relaxation-loss delta-epsilon "delta epsilon")
      (positive-real 'make-relaxation-loss relaxation-time "relaxation time")
      (relaxation-pole delta-epsilon relaxation-time)))
  (material-loss 'relax normalized #f))

(define (material-loss-tangent loss)
  (and loss
       (memq (material-loss-kind loss) '(loss-tangent narrow broad))
       (material-loss-value loss)))

(define (dielectric #:name [name 'dielectric]
                    #:relative-permittivity epsilon-r
                    #:relative-permeability [mu-r 1]
                    #:loss-tangent [loss-tangent #f]
                    #:loss-frequency [loss-frequency 'model]
                    #:loss [loss #f]
                    #:conductivity [conductivity #f])
  (material-name 'dielectric name)
  (positive-real 'dielectric epsilon-r "relative permittivity")
  (positive-real 'dielectric mu-r "relative permeability")
  (when (and loss loss-tangent)
    (raise-arguments-error
     'dielectric "use either loss or loss-tangent, not both"
     "loss" loss "loss-tangent" loss-tangent))
  (when (and loss-tangent conductivity)
    (raise-arguments-error
     'dielectric "use either loss-tangent or conductivity, not both"
     "loss-tangent" loss-tangent "conductivity" conductivity))
  (when loss-tangent
    (positive-real 'dielectric loss-tangent "loss tangent")
    (loss-reference 'dielectric loss-frequency))
  (when conductivity
    (nonnegative-real 'dielectric conductivity "electric conductivity"))
  (when loss
    (unless (material-loss? loss)
      (raise-argument-error 'dielectric "material-loss?" loss))
    (when (and conductivity
               (memq (material-loss-kind loss) '(loss-tangent narrow)))
      (raise-arguments-error
       'dielectric "narrow loss tangent and conductivity are alternative models"
       "loss" loss "conductivity" conductivity)))
  (define base
    (em-material name 'dielectric epsilon-r mu-r (or conductivity 0) 0 #f #f))
  (cond
    [loss (struct-copy em-material base [loss-spec loss])]
    [loss-tangent
      (struct-copy em-material base
        [loss-spec (make-narrow-loss loss-tangent loss-frequency)])]
    [else base]))

(define make-dielectric dielectric)

(define (model-dielectric prototype [factor 2])
  (unless (and (em-material? prototype)
               (eq? (em-material-kind prototype) 'dielectric))
    (raise-argument-error 'model-dielectric "dielectric em-material?" prototype))
  (define tangent (material-loss-tangent (em-material-loss-spec prototype)))
  (unless tangent
    (raise-arguments-error
     'model-dielectric
     "prototype must provide a nominal loss tangent"
     "prototype" prototype))
  (struct-copy em-material prototype
    [loss-spec (make-model-broad-loss tangent factor)]))

(define (conductor #:name [name 'conductor]
                   #:conductivity conductivity
                   #:sheet-thickness [sheet-thickness #f])
  (material-name 'conductor name)
  (positive-real 'conductor conductivity "electric conductivity")
  (when sheet-thickness
    (positive-real 'conductor sheet-thickness "default sheet thickness"))
  ;; A conductor's catalog thickness is an absolute physical property in
  ;; meters.  Unlike explicit geometry dimensions, it is never affected by
  ;; current-geometry-scale.
  (em-material name 'conductor #f #f conductivity 0 sheet-thickness #f))

(define make-conductor conductor)

;; Compatibility constructor. New code should normally use a conductor and
;; place the physical thickness on each sheet.
(define (conducting-sheet-material
         #:name [name 'conducting-sheet]
         #:conductivity [conductivity 0]
         #:thickness [thickness 0])
  (material-name 'conducting-sheet-material name)
  (nonnegative-real 'conducting-sheet-material conductivity "electric conductivity")
  (nonnegative-real 'conducting-sheet-material thickness "sheet thickness")
  (em-material name 'conducting-sheet #f #f conductivity 0 thickness #f))

(define (material-default-precedence material)
  (unless (em-material? material)
    (raise-argument-error 'material-default-precedence "em-material?" material))
  (case (em-material-kind material)
    [(dielectric) 10]
    [(pec conductor conducting-sheet) 20]
    [else 10]))
