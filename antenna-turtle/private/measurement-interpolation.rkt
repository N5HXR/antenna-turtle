#lang racket/base

(require racket/list
         racket/math)

(provide
 approximately=?
 interpolate-number
 interpolate-complex
 interpolate-db-power
 sample-at-frequency
 normalize-azimuth
 angular-distance-deg)

;; Query helpers kept separate from result-type dispatch.  Frequencies emitted
;; by solver CSV files have passed through decimal text, so exact lookup uses a
;; small relative tolerance rather than bit-for-bit floating-point equality.
(define (approximately=? left right [relative-tolerance 1e-9])
  (<= (abs (- left right))
      (* relative-tolerance (max 1.0 (abs left) (abs right)))))

(define (interpolate-number left right fraction)
  (+ left (* fraction (- right left))))

(define (interpolate-complex left right fraction)
  (make-rectangular
   (interpolate-number (real-part left) (real-part right) fraction)
   (interpolate-number (imag-part left) (imag-part right) fraction)))

(define (db->power db) (expt 10.0 (/ db 10.0)))
(define (power->db power)
  (if (zero? power) -inf.0 (* 10.0 (/ (log power) (log 10.0)))))

(define (interpolate-db-power left right fraction)
  (power->db
   (interpolate-number (db->power left) (db->power right) fraction)))

;; Return the selected or interpolated value.  VALUE-AT extracts the quantity
;; from each item, and INTERPOLATE combines the two bracketing quantities.
(define (sample-at-frequency who items frequency frequency-at value-at
                             interpolate interpolate?)
  (unless (and (real? frequency)
               (not (infinite? frequency))
               (not (nan? frequency)))
    (raise-argument-error who "finite real frequency in MHz" frequency))
  (define ordered
    (sort items < #:key frequency-at))
  (when (null? ordered)
    (raise-arguments-error who "the result contains no matching samples"))
  (define exact
    (findf (lambda (item)
             (approximately=? (frequency-at item) frequency))
           ordered))
  (cond
    [exact (value-at exact)]
    [(not interpolate?)
     (raise-arguments-error
      who
      "no sample exists at the requested frequency; enable interpolation or choose an available frequency"
      "requested frequency (MHz)" frequency
      "available frequencies (MHz)" (map frequency-at ordered))]
    [else
     (define lower
       (for/fold ([candidate #f]) ([item (in-list ordered)]
                                   #:when (< (frequency-at item) frequency))
         item))
     (define upper
       (for/first ([item (in-list ordered)]
                   #:when (> (frequency-at item) frequency))
         item))
     (unless (and lower upper)
       (raise-arguments-error
        who
        "cannot extrapolate beyond the sampled frequency range"
        "requested frequency (MHz)" frequency
        "sampled range (MHz)"
        (list (frequency-at (first ordered))
              (frequency-at (last ordered)))))
     (define low-frequency (frequency-at lower))
     (define fraction
       (/ (- frequency low-frequency)
          (- (frequency-at upper) low-frequency)))
     (interpolate (value-at lower) (value-at upper) fraction)]))

(define (normalize-azimuth angle)
  (define normalized (- angle (* 360.0 (floor (/ angle 360.0)))))
  (if (approximately=? normalized 360.0) 0.0 normalized))

(define (degrees->radians degrees) (* degrees (/ pi 180.0)))

(define (angular-distance-deg azimuth-1 elevation-1 azimuth-2 elevation-2)
  (define az1 (degrees->radians azimuth-1))
  (define el1 (degrees->radians elevation-1))
  (define az2 (degrees->radians azimuth-2))
  (define el2 (degrees->radians elevation-2))
  (define dot
    (+ (* (cos el1) (cos az1) (cos el2) (cos az2))
       (* (cos el1) (sin az1) (cos el2) (sin az2))
       (* (sin el1) (sin el2))))
  (* (acos (max -1.0 (min 1.0 dot))) (/ 180.0 pi)))
