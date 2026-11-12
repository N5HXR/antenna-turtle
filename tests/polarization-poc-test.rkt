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

(test-case "gain brightness is bounded, nonlinear, and emphasizes strong lobes"
  (check-= (gain->brightness -20 -20 10) 0.1 1e-12)
  (check-= (gain->brightness 10 -20 10) 1.25 1e-12)
  (check-= (gain->brightness -5 -20 10)
           (+ 0.1 (* 1.15 (expt 0.5 1.2))) 1e-12)
  (check-= (gain->brightness -100 -20 10) 0.1 1e-12)
  (check-= (gain->brightness 100 -20 10) 1.25 1e-12)
  (check-= (gain->brightness 3 3 3) 1.0 1e-12))

(define (check-rgb actual expected [epsilon 1e-10])
  (for ([channel (in-list actual)] [wanted (in-list expected)])
    (check-= channel wanted epsilon)))

(test-case "signed circularity has fixed LHCP/linear/RHCP anchors"
  (check-rgb (signed-circularity-color -1) '(255 32 128))
  (check-rgb (signed-circularity-color 0) '(128 255 32))
  (check-rgb (signed-circularity-color 1) '(32 128 255))
  (check-rgb (signed-circularity-color -0.5) '(191.5 143.5 80))
  (check-rgb (signed-circularity-color 0.5) '(80 191.5 143.5))
  (check-rgb (signed-circularity-color #f) '(20 20 26))
  (check-exn exn:fail:contract?
             (lambda () (signed-circularity-color 1.1))))

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

(define polarization-color-grid
  (nec2c-pattern-grid
   #f '(90) '(0 90 180)
   (list
    (nec2c-pattern-sample
     435 90 0 0 0 0 0 0 1 #f 'rhcp 1+0i 0-1i)
    (nec2c-pattern-sample
     435 90 90 0 90 0 0 0 +inf.0 0 'linear 1+0i 0+0i)
    (nec2c-pattern-sample
     435 90 180 0 180 0 0 0 1 #f 'lhcp 1+0i 0+1i))))

(test-case "surface color cache derives circularity from complex fields"
  (define color-at (make-polarization-color-at polarization-color-grid))
  (check-rgb (color-at 90 0) '(32 128 255))
  (check-rgb (color-at 90 90) '(128 255 32))
  (check-rgb (color-at 90 180) '(255 32 128))
  ;; The cyclic seam resolves to the same RHCP sample as zero degrees.
  (check-rgb (color-at 90 360) '(32 128 255))
  (check-rgb (color-at 45 45) '(20 20 26)))

(define gain-brightness-grid
  (nec2c-pattern-grid
   #f '(90) '(0 90 180)
   (for/list ([phi (in-list '(0 90 180))]
              [gain (in-list '(-20 -5 10))])
     (nec2c-pattern-sample
      435 90 phi 0 phi 0 0 gain 1 #f 'rhcp 1+0i 0-1i))))

(test-case "surface color combines polarization hue with gain brightness"
  (define color-at (make-polarization-color-at gain-brightness-grid))
  (define base-rhcp '(32 128 255))
  (check-rgb (color-at 90 0)
             (map (lambda (channel) (* 0.1 channel)) base-rhcp))
  (check-rgb (color-at 90 90)
             (map (lambda (channel)
                    (* (gain->brightness -5 -20 10) channel))
                  base-rhcp))
  (check-rgb (color-at 90 180) '(40 160 255)))

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
