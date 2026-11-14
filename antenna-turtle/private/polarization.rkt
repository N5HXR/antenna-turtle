#lang racket/base

(require racket/math)

(provide
 stokes-parameters
 circular-components
 analyze-polarization
 (struct-out polarization-state))

;; Antenna Turtle uses Re(E exp(j omega t)) for instantaneous phasors. With
;; the observer behind the antenna looking along propagation, E_phi = -j
;; E_theta is therefore clockwise (RHCP). Keeping that convention here makes
;; the solver adapters and every viewer share one authoritative sign choice.
(struct polarization-state
  (s0 s1 s2 s3
      signed-circularity axial-ratio tilt-deg ellipticity-deg sense
      e-rhcp e-lhcp rhcp-power lhcp-power)
  #:transparent)

(define (field-component who value)
  (unless (number? value)
    (raise-argument-error who "number?" value))
  value)

(define (nonnegative-real who value)
  (unless (and (real? value) (>= value 0))
    (raise-argument-error who "nonnegative-real?" value))
  value)

(define (clamp value low high)
  (max low (min high value)))

(define (stokes-parameters e-theta e-phi)
  (field-component 'stokes-parameters e-theta)
  (field-component 'stokes-parameters e-phi)
  (define theta-power (sqr (magnitude e-theta)))
  (define phi-power (sqr (magnitude e-phi)))
  (define cross (* e-theta (conjugate e-phi)))
  (values (+ theta-power phi-power)
          (- theta-power phi-power)
          (* 2.0 (real-part cross))
          (* 2.0 (imag-part cross))))

(define (circular-components e-theta e-phi)
  (field-component 'circular-components e-theta)
  (field-component 'circular-components e-phi)
  (define root-two (sqrt 2.0))
  ;; These unitary components make |E_R|^2 - |E_L|^2 = S3.
  (values (/ (+ e-theta (* 0+1i e-phi)) root-two)
          (/ (- e-theta (* 0+1i e-phi)) root-two)))

(define (analyze-polarization e-theta e-phi
                              #:tolerance [tolerance 1e-12]
                              #:minimum-power [minimum-power 0.0])
  (field-component 'analyze-polarization e-theta)
  (field-component 'analyze-polarization e-phi)
  (nonnegative-real 'analyze-polarization tolerance)
  (nonnegative-real 'analyze-polarization minimum-power)
  (define-values (s0 s1 s2 s3) (stokes-parameters e-theta e-phi))
  (define-values (e-rhcp e-lhcp) (circular-components e-theta e-phi))
  (define rhcp-power (sqr (magnitude e-rhcp)))
  (define lhcp-power (sqr (magnitude e-lhcp)))
  (cond
    [(<= s0 minimum-power)
     (polarization-state
      s0 s1 s2 s3 #f #f #f #f 'undefined
      e-rhcp e-lhcp rhcp-power lhcp-power)]
    [else
     (define circularity (clamp (/ s3 s0) -1.0 1.0))
     (define ellipticity-radians (* 0.5 (asin circularity)))
     (define ellipticity-deg (radians->degrees ellipticity-radians))
     (define minor/major (abs (tan ellipticity-radians)))
     (define axial-ratio
       (if (<= minor/major tolerance)
           +inf.0
           (max 1.0 (/ 1.0 minor/major))))
     ;; A circle has no distinguished major-axis direction. The normalized
     ;; linear Stokes magnitude detects that degeneracy without depending on
     ;; absolute field amplitude.
     (define linear-stokes
       (/ (sqrt (+ (sqr s1) (sqr s2))) s0))
     (define tilt-deg
       (and (> linear-stokes tolerance)
            (* 0.5 (radians->degrees (atan s2 s1)))))
     (define sense
       (cond
         [(<= (abs circularity) tolerance) 'linear]
         [(positive? circularity) 'rhcp]
         [else 'lhcp]))
     (polarization-state
      s0 s1 s2 s3 circularity axial-ratio tilt-deg ellipticity-deg sense
      e-rhcp e-lhcp rhcp-power lhcp-power)]))
