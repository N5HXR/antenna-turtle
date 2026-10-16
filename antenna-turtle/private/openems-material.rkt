#lang racket/base

(require racket/math
         "material.rkt")

(provide vacuum-permittivity
         vacuum-permeability
         dielectric-loss-kind
         dielectric-dispersive?
         dielectric-reference-frequency-mhz
         dielectric-broadband-range-mhz
         dielectric-effective-conductivity
         dielectric-effective-loss-tangent
         dielectric-maximum-relative-permittivity
         conductor-skin-depth
         conductor-effective-sheet-thickness)

(define vacuum-permittivity 8.8541878128e-12)
(define vacuum-permeability (* 4 pi 1e-7))

(define (dielectric-loss-kind material)
  (define loss (em-material-loss-spec material))
  (and loss
       (case (material-loss-kind loss)
         [(loss-tangent narrow) 'narrow]
         [(broad) 'broad]
         [(relax) 'relax]
         [else (material-loss-kind loss)])))

(define (dielectric-dispersive? material)
  (memq (dielectric-loss-kind material) '(broad relax)))

(define (resolve-model-reference reference model-frequency-mhz)
  (if (eq? reference 'model) model-frequency-mhz reference))

(define (dielectric-reference-frequency-mhz material model-frequency-mhz)
  (define loss (em-material-loss-spec material))
  (and loss
       (case (dielectric-loss-kind material)
         [(broad)
          (resolve-model-reference
           (broadband-loss-range-reference-frequency
            (material-loss-reference-frequency loss))
           model-frequency-mhz)]
         [(relax) #f]
         [else
          (resolve-model-reference
           (material-loss-reference-frequency loss) model-frequency-mhz)])))

(define (dielectric-broadband-range-mhz material model-frequency-mhz)
  (define loss (em-material-loss-spec material))
  (and loss
       (eq? (dielectric-loss-kind material) 'broad)
       (let* ([range (material-loss-reference-frequency loss)]
              [factor (broadband-loss-range-model-factor range)])
         (if factor
             (values (/ model-frequency-mhz factor)
                     (* model-frequency-mhz factor))
             (values (broadband-loss-range-lower-frequency range)
                     (broadband-loss-range-upper-frequency range))))))

(define (dielectric-effective-conductivity material model-frequency-mhz)
  (define loss (em-material-loss-spec material))
  (if (and loss (eq? (dielectric-loss-kind material) 'narrow))
      (let ([frequency-mhz
             (dielectric-reference-frequency-mhz material model-frequency-mhz)])
        (* 2 pi (* frequency-mhz 1e6)
           vacuum-permittivity
           (em-material-relative-permittivity material)
           (material-loss-value loss)))
      (or (em-material-electric-conductivity material) 0)))

(define (log10 value)
  (/ (log value) (log 10)))

(define (broadband-parameters material model-frequency-mhz)
  (define loss (em-material-loss-spec material))
  (define-values (lower-mhz upper-mhz)
    (dielectric-broadband-range-mhz material model-frequency-mhz))
  (define reference-mhz
    (dielectric-reference-frequency-mhz material model-frequency-mhz))
  (unless (<= lower-mhz reference-mhz upper-mhz)
    (raise-arguments-error
     'dielectric
     "broadband reference frequency must lie within its loss range"
     "reference frequency (MHz)" reference-mhz
     "loss range (MHz)" (list lower-mhz upper-mhz)
     "material" (em-material-name material)))
  (define w1 (* 2 pi lower-mhz 1e6))
  (define w2 (* 2 pi upper-mhz 1e6))
  (define wm (* 2 pi reference-mhz 1e6))
  (define epsilon-r (em-material-relative-permittivity material))
  (define tangent (material-loss-value loss))
  (define sigma (or (em-material-electric-conductivity material) 0))
  (define ratio (/ (+ w2 (* 0+1i wm)) (+ w1 (* 0+1i wm))))
  (define k
    (/ (* (log 10)
          (- (+ (* tangent epsilon-r)
                (/ sigma (* vacuum-permittivity wm)))))
       (angle ratio)))
  (define epsilon-infinity
    (- epsilon-r (* k (log10 (magnitude ratio)))))
  (define delta-epsilon
    (* k (- (log10 w2) (log10 w1))))
  (values epsilon-infinity delta-epsilon w1 w2 sigma))

(define (dielectric-complex-relative-permittivity material frequency-mhz
                                                  model-frequency-mhz)
  (define epsilon-r (em-material-relative-permittivity material))
  (define omega (* 2 pi frequency-mhz 1e6))
  (case (dielectric-loss-kind material)
    [(broad)
     (define-values (epsilon-infinity delta-epsilon w1 w2 sigma)
       (broadband-parameters material model-frequency-mhz))
     (+ epsilon-infinity
        (* (/ delta-epsilon (- (log10 w2) (log10 w1)))
           (log10 (/ (+ w2 (* 0+1i omega))
                     (+ w1 (* 0+1i omega)))))
        (* 0-1i (/ sigma (* omega vacuum-permittivity))))]
    [(relax)
     (+ epsilon-r
        (for/sum ([pole (in-list
                         (material-loss-value
                          (em-material-loss-spec material)))])
          (/ (relaxation-pole-delta-epsilon pole)
             (+ 1 (* 0+1i omega
                     (relaxation-pole-relaxation-time pole)))))
        (* 0-1i
           (/ (or (em-material-electric-conductivity material) 0)
              (* omega vacuum-permittivity))))]
    [else epsilon-r]))

(define (dielectric-effective-loss-tangent material frequency-mhz model-frequency-mhz)
  (if (dielectric-dispersive? material)
      (let ([epsilon
             (dielectric-complex-relative-permittivity
              material frequency-mhz model-frequency-mhz)])
        (/ (- (imag-part epsilon)) (real-part epsilon)))
      (let ([conductivity
             (dielectric-effective-conductivity material model-frequency-mhz)])
        (if (zero? conductivity)
            0
            (/ conductivity
               (* 2 pi (* frequency-mhz 1e6)
                  vacuum-permittivity
                  (em-material-relative-permittivity material)))))))

(define (dielectric-maximum-relative-permittivity material model-frequency-mhz)
  (case (dielectric-loss-kind material)
    [(broad)
     (define-values (epsilon-infinity delta-epsilon _w1 _w2 _sigma)
       (broadband-parameters material model-frequency-mhz))
     (+ epsilon-infinity delta-epsilon)]
    [(relax)
     (+ (em-material-relative-permittivity material)
        (for/sum ([pole (in-list
                         (material-loss-value
                          (em-material-loss-spec material)))])
          (relaxation-pole-delta-epsilon pole)))]
    [else (em-material-relative-permittivity material)]))

(define (conductor-skin-depth material frequency-mhz)
  (sqrt (/ 2
           (* 2 pi (* frequency-mhz 1e6)
              vacuum-permeability
              (em-material-electric-conductivity material)))))

(define (conductor-effective-sheet-thickness material physical-thickness
                                             reference-frequency-mhz)
  ;; Preserve normal foil thickness verbatim. AddConductingSheet explicitly
  ;; discourages values above 500 um; for those bulk walls, ten skin depths
  ;; captures the narrowband surface response without leaving its fit range.
  (if (<= physical-thickness 500e-6)
      physical-thickness
      (min 500e-6
           (max 1e-6
                (* 10 (conductor-skin-depth material reference-frequency-mhz))))))
