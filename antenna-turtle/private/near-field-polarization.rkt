#lang racket/base

(require racket/list
         racket/math
         "near-field-particle.rkt")

(provide (struct-out near-field-polarization-ellipse)
         analyze-near-field-polarization
         near-field-polarization-at
         near-field-electric-spin
         near-field-instantaneous-electric)

;; The phasor uses Antenna Turtle's e^(+jwt) convention, so the instantaneous
;; field is Re(E e^(jwt)) = Re(E) cos(wt) - Im(E) sin(wt).
(struct near-field-polarization-ellipse
  (electric major-axis minor-axis normal major-amplitude minor-amplitude)
  #:transparent)

(define (vector3-dot a b)
  (for/sum ([x (in-list a)] [y (in-list b)]) (* x y)))

(define (vector3-scale vector scalar)
  (map (lambda (value) (* value scalar)) vector))

(define (vector3+ a b)
  (map + a b))

(define (vector3-cross a b)
  (list (- (* (second a) (third b)) (* (third a) (second b)))
        (- (* (third a) (first b)) (* (first a) (third b)))
        (- (* (first a) (second b)) (* (second a) (first b)))))

(define (vector3-length vector)
  (sqrt (max 0.0 (vector3-dot vector vector))))

(define (vector3-normalize vector)
  (define length (vector3-length vector))
  (and (> length 1e-14) (vector3-scale vector (/ length))))

(define (validate-electric who electric)
  (unless (and (list? electric) (= (length electric) 3)
               (andmap number? electric))
    (raise-argument-error who "(list/c number? number? number?)" electric)))

(define (near-field-instantaneous-electric electric phase-radians)
  (validate-electric 'near-field-instantaneous-electric electric)
  (unless (real? phase-radians)
    (raise-argument-error
     'near-field-instantaneous-electric "real?" phase-radians))
  (define cosine (cos phase-radians))
  (define sine (sin phase-radians))
  (for/list ([value (in-list electric)])
    (- (* (real-part value) cosine)
       (* (imag-part value) sine))))

;; Dimensionless electric spin.  With Antenna Turtle's e^(+jwt) convention,
;; opposite rotations reverse the vector.  Its magnitude is zero for linear
;; motion and one for an ideal circle, making it useful as a diagrammatic
;; direction/circularity glyph without introducing an arbitrary field scale.
(define (near-field-electric-spin electric)
  (validate-electric 'near-field-electric-spin electric)
  (define energy
    (for/sum ([value (in-list electric)]) (sqr (magnitude value))))
  (if (<= energy 1e-28)
      '(0.0 0.0 0.0)
      (map (lambda (value) (/ (imag-part value) energy))
           (vector3-cross (map conjugate electric) electric))))

(define (principal-coefficients aa bb ab eigenvalue)
  (define raw
    (cond
      [(> (abs ab) 1e-14) (list ab (- eigenvalue aa))]
      [(>= aa bb) '(1.0 0.0)]
      [else '(0.0 1.0)]))
  (define coefficient-norm
    (sqrt (+ (sqr (first raw)) (sqr (second raw)))))
  (map (lambda (component) (/ component coefficient-norm)) raw))

(define (analyze-near-field-polarization electric)
  (validate-electric 'analyze-near-field-polarization electric)
  (define cosine-axis (map real-part electric))
  (define sine-axis (map (lambda (value) (- (imag-part value))) electric))
  ;; Singular values of the 3x2 [cosine-axis sine-axis] matrix are the
  ;; physical semi-axis field amplitudes. Compute them through its 2x2 Gram
  ;; matrix to avoid importing a numerical linear-algebra dependency.
  (define aa (vector3-dot cosine-axis cosine-axis))
  (define bb (vector3-dot sine-axis sine-axis))
  (define ab (vector3-dot cosine-axis sine-axis))
  (define trace (+ aa bb))
  (define discriminant
    (sqrt (max 0.0 (+ (sqr (- aa bb)) (* 4.0 (sqr ab))))))
  (define major-eigenvalue (/ (+ trace discriminant) 2.0))
  (define minor-eigenvalue (max 0.0 (/ (- trace discriminant) 2.0)))
  (cond
    [(<= major-eigenvalue 1e-28) #f]
    [else
     (define major-amplitude (sqrt major-eigenvalue))
     (define minor-amplitude (sqrt minor-eigenvalue))
     (define coefficients
       (principal-coefficients aa bb ab major-eigenvalue))
     (define major-axis
       (vector3-normalize
        (vector3+
         (vector3-scale cosine-axis (first coefficients))
         (vector3-scale sine-axis (second coefficients)))))
     (define minor-axis
       (and (> minor-amplitude (* major-amplitude 1e-12))
            (vector3-normalize
             (vector3+
              (vector3-scale cosine-axis (- (second coefficients)))
              (vector3-scale sine-axis (first coefficients))))))
     (define normal
       (and minor-axis
            (vector3-normalize (vector3-cross major-axis minor-axis))))
     (near-field-polarization-ellipse
      electric major-axis minor-axis normal
      major-amplitude minor-amplitude)]))

(define (near-field-polarization-at field u v)
  (unless (near-field-flow-field? field)
    (raise-argument-error
     'near-field-polarization-at "near-field-flow-field?" field))
  (define electric (near-field-flow-electric field u v))
  (and electric (analyze-near-field-polarization electric)))
