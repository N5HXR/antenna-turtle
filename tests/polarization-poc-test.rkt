#lang racket/base

(require pict3d
         rackunit
         racket/math
         "../antenna-turtle/private/nec2c.rkt"
         "../antenna-turtle/private/nec2c-opengl-view.rkt"
         "../antenna-turtle/private/polarization-poc.rkt")

(define (check-angle point expected-azimuth expected-elevation)
  (define-values (azimuth elevation)
    (apply surface-point->angles point))
  (check-= azimuth expected-azimuth 1e-10)
  (check-= elevation expected-elevation 1e-10))

(test-case "surface points use public azimuth/elevation directions"
  (check-angle '(1 0 0) 0 0)
  (check-angle '(0 1 0) 90 0)
  (check-angle '(-1 0 0) 180 0)
  (check-angle '(0 -1 0) 270 0)
  (check-angle '(0 0 1) 0 90)
  (check-angle '(0 0 -1) 0 -90)
  (check-angle '(1 1 1) 45 (radians->degrees (asin (/ 1 (sqrt 3))))))

(test-case "RF phase advances, scales, and wraps continuously"
  (check-= (advance-polarization-phase 0 1 1) 180 1e-12)
  (check-= (advance-polarization-phase 350 0.1 1) 8 1e-12)
  (check-= (advance-polarization-phase 10 1 2) 10 1e-12))

(test-case "PoC math rejects undefined directions and bad timing"
  (check-exn #rx"RF origin" (lambda () (surface-point->angles 0 0 0)))
  (check-exn exn:fail:contract?
             (lambda () (advance-polarization-phase 0 -1 1)))
  (check-exn exn:fail:contract?
             (lambda () (advance-polarization-phase 0 1 0))))

(define theta-values '(0 45 90 135 180))
(define phi-values '(0 45 90 135 180 225 270 315))
(define spherical-grid
  (nec2c-pattern-grid
   #f theta-values phi-values
   (for*/list ([theta (in-list theta-values)]
               [phi (in-list phi-values)])
     (nec2c-pattern-sample
      435 theta phi (- 90 theta) phi
      0 0 0 +inf.0 0 'linear 1+0i 0+0i))))

(test-case "camera rays trace the displayed radial surface exactly"
  (define-values (surface _radius _center _peak)
    (build-radiation-pict3d spherical-grid #:mesh-step 45))
  (define hit (trace surface (pos 3 0 0) (dir -1 0 0)))
  (check-not-false hit)
  (check-= (pos-x hit) 1.0 1e-10)
  (check-= (pos-y hit) 0.0 1e-10)
  (check-= (pos-z hit) 0.0 1e-10)
  (define-values (azimuth elevation)
    (surface-point->angles (pos-x hit) (pos-y hit) (pos-z hit)))
  (check-= azimuth 0.0 1e-10)
  (check-= elevation 0.0 1e-10))
