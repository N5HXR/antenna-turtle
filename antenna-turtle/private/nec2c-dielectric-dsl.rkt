#lang racket/base

(require "nec2c-dielectric.rkt"
         (for-syntax racket/base racket/list syntax/parse))

(provide nec2c-dielectric-mesh)

(begin-for-syntax
  (define (settings who stx items allowed description)
    (define values (syntax->list items))
    (when (odd? (length values))
      (raise-syntax-error who description stx))
    (define result (make-hasheq))
    (for ([offset (in-range 0 (length values) 2)])
      (define key-stx (list-ref values offset))
      (unless (identifier? key-stx)
        (raise-syntax-error who "expected a contextual setting name" stx key-stx))
      (define key (syntax-e key-stx))
      (unless (memq key allowed)
        (raise-syntax-error who description stx key-stx))
      (when (hash-has-key? result key)
        (raise-syntax-error who "setting may be specified only once" stx key-stx))
      (hash-set! result key (list-ref values (add1 offset))))
    result))

(define-syntax (nec2c-dielectric-mesh stx)
  (syntax-parse stx
    [(_ setting ...)
     (define values
       (settings
        'nec2c-dielectric-mesh stx #'(setting ...)
        '(mode max-kh max-cells max-aspect snap-wavelength-divisor snap-feature-divisor)
        "expected mode, max-kh, max-cells, max-aspect, snap-wavelength-divisor, or snap-feature-divisor setting/value pairs"))
     (define mode-stx (hash-ref values 'mode #'manual))
     (define mode (and (identifier? mode-stx) (syntax-e mode-stx)))
     (unless (memq mode '(manual auto))
       (raise-syntax-error 'nec2c-dielectric-mesh
                           "mode must be the contextual identifier manual or auto"
                           stx mode-stx))
     (when (and (eq? mode 'auto) (hash-has-key? values 'max-aspect))
       (raise-syntax-error 'nec2c-dielectric-mesh
                           "automatic meshes are cubic; omit max-aspect"
                           stx (hash-ref values 'max-aspect)))
     (when (and (eq? mode 'manual)
                (or (hash-has-key? values 'snap-wavelength-divisor)
                    (hash-has-key? values 'snap-feature-divisor)))
       (raise-syntax-error 'nec2c-dielectric-mesh
                           "snap settings require mode auto"
                           stx))
     (if (eq? mode 'auto)
         #`(current-nec2c-dielectric-mesh
            (nec2c-dielectric-auto-mesh-spec
             #,(hash-ref values 'max-kh #'0.5)
             #,(hash-ref values 'max-cells #'1000)
             #,(hash-ref values 'snap-wavelength-divisor #'1000)
             #,(hash-ref values 'snap-feature-divisor #'100)))
         #`(current-nec2c-dielectric-mesh
            (nec2c-dielectric-mesh-spec
             #,(hash-ref values 'max-kh #'0.5)
             #,(hash-ref values 'max-cells #'1000)
             #,(hash-ref values 'max-aspect #'2.0))))]))
