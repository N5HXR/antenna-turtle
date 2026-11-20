#lang racket/base

(require rackunit
         racket/math
         "../antenna-turtle/private/polarization.rkt")

(define epsilon 1e-10)

(define (check-close actual expected [message #f])
  (check-= actual expected epsilon message))

(define (check-power-identities state)
  (check-close
   (+ (polarization-state-rhcp-power state)
      (polarization-state-lhcp-power state))
   (polarization-state-s0 state))
  (check-close
   (- (polarization-state-rhcp-power state)
      (polarization-state-lhcp-power state))
   (polarization-state-s3 state))
  (check-close
   (sqr (polarization-state-s0 state))
   (+ (sqr (polarization-state-s1 state))
      (sqr (polarization-state-s2 state))
      (sqr (polarization-state-s3 state)))))

(test-case "linear states have infinite axial ratio and meaningful tilt"
  (define horizontal (analyze-polarization 1 0))
  (check-eq? (polarization-state-sense horizontal) 'linear)
  (check-equal? (polarization-state-signed-circularity horizontal) 0.0)
  (check-true (infinite? (polarization-state-axial-ratio horizontal)))
  (check-close (polarization-state-tilt-deg horizontal) 0.0)
  (check-close (polarization-state-rhcp-power horizontal) 0.5)
  (check-close (polarization-state-lhcp-power horizontal) 0.5)
  (check-power-identities horizontal)

  (define diagonal
    (analyze-polarization (/ 1.0 (sqrt 2.0))
                          (/ 1.0 (sqrt 2.0))))
  (check-eq? (polarization-state-sense diagonal) 'linear)
  (check-close (polarization-state-tilt-deg diagonal) 45.0)
  (check-true (infinite? (polarization-state-axial-ratio diagonal)))
  (check-power-identities diagonal))

(test-case "RHCP and LHCP follow the propagation-facing convention"
  (define component (/ 1.0 (sqrt 2.0)))
  (define rhcp (analyze-polarization component (* 0-1i component)))
  (define lhcp (analyze-polarization component (* 0+1i component)))
  (check-eq? (polarization-state-sense rhcp) 'rhcp)
  (check-eq? (polarization-state-sense lhcp) 'lhcp)
  (check-close (polarization-state-signed-circularity rhcp) 1.0)
  (check-close (polarization-state-signed-circularity lhcp) -1.0)
  (check-close (polarization-state-axial-ratio rhcp) 1.0)
  (check-close (polarization-state-axial-ratio lhcp) 1.0)
  (check-false (polarization-state-tilt-deg rhcp))
  (check-false (polarization-state-tilt-deg lhcp))
  (check-close (magnitude (polarization-state-e-rhcp rhcp)) 1.0)
  (check-close (magnitude (polarization-state-e-lhcp rhcp)) 0.0)
  (check-close (magnitude (polarization-state-e-rhcp lhcp)) 0.0)
  (check-close (magnitude (polarization-state-e-lhcp lhcp)) 1.0)
  (check-power-identities rhcp)
  (check-power-identities lhcp))

(test-case "known and rotated ellipses report axial ratio and tilt"
  (define chi (degrees->radians 30.0))
  (define psi (degrees->radians 30.0))
  (define unrotated
    (analyze-polarization (cos chi) (* 0-1i (sin chi))))
  (check-eq? (polarization-state-sense unrotated) 'rhcp)
  (check-close (polarization-state-signed-circularity unrotated)
               (sin (* 2.0 chi)))
  (check-close (polarization-state-ellipticity-deg unrotated) 30.0)
  (check-close (polarization-state-axial-ratio unrotated) (sqrt 3.0))
  (check-close (polarization-state-tilt-deg unrotated) 0.0)

  (define rotated-e-theta
    (- (* (cos chi) (cos psi))
       (* 0-1i (sin chi) (sin psi))))
  (define rotated-e-phi
    (+ (* (cos chi) (sin psi))
       (* 0-1i (sin chi) (cos psi))))
  (define rotated (analyze-polarization rotated-e-theta rotated-e-phi))
  (check-close (polarization-state-tilt-deg rotated) 30.0)
  (check-close (polarization-state-ellipticity-deg rotated) 30.0)
  (check-close (polarization-state-axial-ratio rotated) (sqrt 3.0))
  (check-power-identities rotated))

(test-case "normalized polarization is invariant to scale and global phase"
  (define original (analyze-polarization 0.8+0.1i -0.2+0.55i))
  (define phase (make-polar 7.0 0.73))
  (define transformed
    (analyze-polarization (* phase 0.8+0.1i)
                          (* phase -0.2+0.55i)))
  (check-close (polarization-state-signed-circularity transformed)
               (polarization-state-signed-circularity original))
  (check-close (polarization-state-axial-ratio transformed)
               (polarization-state-axial-ratio original))
  (check-close (polarization-state-tilt-deg transformed)
               (polarization-state-tilt-deg original))
  (check-eq? (polarization-state-sense transformed)
             (polarization-state-sense original)))

(test-case "zero and below-threshold fields are explicitly undefined"
  (define zero (analyze-polarization 0 0))
  (check-eq? (polarization-state-sense zero) 'undefined)
  (check-false (polarization-state-signed-circularity zero))
  (check-false (polarization-state-axial-ratio zero))
  (check-false (polarization-state-tilt-deg zero))
  (define weak
    (analyze-polarization 1e-8 0 #:minimum-power 1e-12))
  (check-eq? (polarization-state-sense weak) 'undefined))

(test-case "field APIs reject invalid values and tolerances"
  (check-exn exn:fail:contract?
             (lambda () (analyze-polarization 'bad 0)))
  (check-exn exn:fail:contract?
             (lambda () (analyze-polarization 1 0 #:tolerance -1)))
  (check-exn exn:fail:contract?
             (lambda () (analyze-polarization 1 0 #:minimum-power -1))))
