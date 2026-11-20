#lang racket/base

(require rackunit
         racket/list
         racket/math
         "../antenna-turtle/private/nec2c.rkt"
         "../antenna-turtle/private/near-field-particle.rkt"
         "../antenna-turtle/private/near-field-polarization.rkt")

(define (check-vector actual expected [epsilon 1e-10])
  (for ([value (in-list actual)] [wanted (in-list expected)])
    (check-= value wanted epsilon)))

(define (absolute-dot a b)
  (abs (for/sum ([x (in-list a)] [y (in-list b)]) (* x y))))

(test-case "linear Cartesian field collapses to a reversing line"
  (define ellipse (analyze-near-field-polarization '(2+0i 0 0)))
  (check-= (near-field-polarization-ellipse-major-amplitude ellipse) 2 1e-12)
  (check-= (near-field-polarization-ellipse-minor-amplitude ellipse) 0 1e-12)
  (check-= (absolute-dot
            (near-field-polarization-ellipse-major-axis ellipse) '(1 0 0))
           1 1e-12)
  (check-false (near-field-polarization-ellipse-minor-axis ellipse))
  (check-vector (near-field-instantaneous-electric '(2+0i 0 0) 0) '(2 0 0))
  (check-vector (near-field-instantaneous-electric '(2+0i 0 0) pi) '(-2 0 0)))

(test-case "quadrature sign reverses circular traversal"
  (define positive (analyze-near-field-polarization '(1+0i 0+1i 0)))
  (define negative (analyze-near-field-polarization '(1+0i 0-1i 0)))
  (for ([ellipse (in-list (list positive negative))])
    (check-= (near-field-polarization-ellipse-major-amplitude ellipse) 1 1e-12)
    (check-= (near-field-polarization-ellipse-minor-amplitude ellipse) 1 1e-12))
  (check-vector
   (near-field-instantaneous-electric
    (near-field-polarization-ellipse-electric positive) (/ pi 2))
   '(0 -1 0))
  (check-vector
   (near-field-instantaneous-electric
    (near-field-polarization-ellipse-electric negative) (/ pi 2))
   '(0 1 0)))

(test-case "normalized electric spin distinguishes linear and circular fields"
  (check-vector (near-field-electric-spin '(2+0i 0 0)) '(0 0 0))
  (check-vector (near-field-electric-spin '(1+0i 0+1i 0)) '(0 0 1))
  (check-vector (near-field-electric-spin '(1+0i 0-1i 0)) '(0 0 -1))
  (define elliptical (near-field-electric-spin '(2+0i 0+1i 0)))
  (check-true (< 0 (absolute-dot elliptical '(0 0 1)) 1)))

(test-case "unequal quadrature components retain physical axial ratio"
  (define ellipse (analyze-near-field-polarization '(2+0i 0+1i 0)))
  (check-= (near-field-polarization-ellipse-major-amplitude ellipse) 2 1e-12)
  (check-= (near-field-polarization-ellipse-minor-amplitude ellipse) 1 1e-12)
  (check-= (/ (near-field-polarization-ellipse-major-amplitude ellipse)
              (near-field-polarization-ellipse-minor-amplitude ellipse))
           2 1e-12))

(test-case "arbitrary 3D ellipse preserves normal and longitudinal motion"
  (define root-half (/ 1 (sqrt 2)))
  (define ellipse
    (analyze-near-field-polarization
     (list root-half root-half 0-0.5i)))
  (check-= (near-field-polarization-ellipse-major-amplitude ellipse) 1 1e-12)
  (check-= (near-field-polarization-ellipse-minor-amplitude ellipse) 0.5 1e-12)
  (check-= (absolute-dot
            (near-field-polarization-ellipse-major-axis ellipse)
            (list root-half root-half 0))
           1 1e-12)
  (check-= (absolute-dot
            (near-field-polarization-ellipse-minor-axis ellipse) '(0 0 1))
           1 1e-12)
  (define longitudinal (analyze-near-field-polarization '(0 0 3+0i)))
  (check-= (absolute-dot
            (near-field-polarization-ellipse-major-axis longitudinal) '(0 0 1))
           1 1e-12))

(test-case "zero field has no invented polarization trajectory"
  (check-false (analyze-near-field-polarization '(0 0 0))))

(define interpolation-section
  (nec2c-near-field-section
   'xy 'z 0.0 'x 'y
   '(0.0 2.0) '(0.0 2.0)
   (list
    (nec2c-near-field-sample 0 0 0 '(0+0i 0 0) '(0 0 0))
    (nec2c-near-field-sample 2 0 0 '(2+2i 0 0) '(0 0 0))
    (nec2c-near-field-sample 0 2 0 '(0+2i 2 0) '(0 0 0))
    (nec2c-near-field-sample 2 2 0 '(2+4i 2 0) '(0 0 0)))
   '(electric magnetic)))

(test-case "complex Cartesian fields interpolate before ellipse analysis"
  (define field (make-near-field-flow-field interpolation-section 100))
  (check-equal? (near-field-flow-electric field 1 1) '(1.0+2.0i 1.0 0))
  (check-false (near-field-flow-electric field 3 1))
  (define ellipse (near-field-polarization-at field 1 1))
  (check-true (near-field-polarization-ellipse? ellipse))
  (check-equal? (near-field-polarization-ellipse-electric ellipse)
                '(1.0+2.0i 1.0 0)))

(define poynting-section
  (nec2c-near-field-section
   'xy 'z 0.0 'x 'y
   '(0.0 1.0) '(0.0 1.0)
   (for*/list ([y '(0.0 1.0)] [x '(0.0 1.0)])
     ;; Unit circular plane wave in +Z, omitting the impedance scale:
     ;; H = z-hat × E. Its instantaneous E×H is exactly +Z at every phase.
     (nec2c-near-field-sample
      x y 0.0 '(1+0i 0+1i 0) '(0-1i 1+0i 0)))
   '(electric magnetic)))

(test-case "instantaneous Poynting vector follows phase and stays normal to E(t)"
  (define field (make-near-field-flow-field poynting-section 100))
  (for ([phase (in-list (list 0.0 0.37 (/ pi 2) pi))])
    (define state (near-field-flow-sample field 0.5 0.5 phase 'instantaneous))
    (define electric
      (near-field-instantaneous-electric '(1+0i 0+1i 0) phase))
    (check-vector (near-field-flow-state-poynting state) '(0 0 1))
    (check-= (absolute-dot electric (near-field-flow-state-poynting state))
             0.0 1e-12))
  (check-vector
   (near-field-flow-state-poynting
    (near-field-flow-sample field 0.5 0.5 0.0 'average))
   '(0 0 1))
  (check-vector (near-field-flow-average-poynting field 0.5 0.5)
                '(0 0 1))
  (check-= (near-field-flow-signed-normal-power field 0.5 0.5)
           1.0 1e-12))
