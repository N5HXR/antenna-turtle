#lang racket/base

(require racket/math
         "material.rkt")

(provide vacuum-permittivity
         vacuum-permeability
         dielectric-reference-frequency-mhz
         dielectric-effective-conductivity
         dielectric-effective-loss-tangent
         conductor-skin-depth
         conductor-effective-sheet-thickness)

(define vacuum-permittivity 8.8541878128e-12)
(define vacuum-permeability (* 4 pi 1e-7))

(define (dielectric-reference-frequency-mhz material model-frequency-mhz)
  (define loss (em-material-loss-spec material))
  (and loss
       (let ([reference (material-loss-reference-frequency loss)])
         (if (eq? reference 'model) model-frequency-mhz reference))))

(define (dielectric-effective-conductivity material model-frequency-mhz)
  (define loss (em-material-loss-spec material))
  (if (and loss (eq? (material-loss-kind loss) 'loss-tangent))
      (let ([frequency-mhz
             (dielectric-reference-frequency-mhz material model-frequency-mhz)])
        (* 2 pi (* frequency-mhz 1e6)
           vacuum-permittivity
           (em-material-relative-permittivity material)
           (material-loss-value loss)))
      (or (em-material-electric-conductivity material) 0)))

(define (dielectric-effective-loss-tangent material frequency-mhz model-frequency-mhz)
  (define conductivity
    (dielectric-effective-conductivity material model-frequency-mhz))
  (if (zero? conductivity)
      0
      (/ conductivity
         (* 2 pi (* frequency-mhz 1e6)
            vacuum-permittivity
            (em-material-relative-permittivity material)))))

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
