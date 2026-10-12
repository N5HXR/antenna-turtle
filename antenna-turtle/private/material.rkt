#lang racket/base

(provide
 (struct-out material-loss)
 (struct-out em-material)
 pec
 dielectric
 make-dielectric
 conductor
 make-conductor
 conducting-sheet-material
 material-default-precedence)

;; A dielectric loss may be expressed directly as conductivity, or as a loss
;; tangent whose conductivity is derived by a backend for one reference
;; frequency.  'model means the model's declared center frequency.
(struct material-loss (kind value reference-frequency) #:transparent)

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

(define (dielectric #:name [name 'dielectric]
                    #:relative-permittivity epsilon-r
                    #:relative-permeability [mu-r 1]
                    #:loss-tangent [loss-tangent #f]
                    #:loss-frequency [loss-frequency 'model]
                    #:conductivity [conductivity #f])
  (material-name 'dielectric name)
  (positive-real 'dielectric epsilon-r "relative permittivity")
  (positive-real 'dielectric mu-r "relative permeability")
  (when (and loss-tangent conductivity)
    (raise-arguments-error
     'dielectric "use either loss-tangent or conductivity, not both"
     "loss-tangent" loss-tangent "conductivity" conductivity))
  (when loss-tangent
    (positive-real 'dielectric loss-tangent "loss tangent")
    (loss-reference 'dielectric loss-frequency))
  (when conductivity
    (nonnegative-real 'dielectric conductivity "electric conductivity"))
  (define base
    (em-material name 'dielectric epsilon-r mu-r (or conductivity 0) 0 #f #f))
  (if loss-tangent
      (struct-copy em-material base
        [loss-spec (material-loss 'loss-tangent loss-tangent loss-frequency)])
      base))

(define make-dielectric dielectric)

(define (conductor #:name [name 'conductor] #:conductivity conductivity)
  (material-name 'conductor name)
  (positive-real 'conductor conductivity "electric conductivity")
  (em-material name 'conductor #f #f conductivity 0 #f #f))

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
