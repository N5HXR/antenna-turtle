#lang racket/base

(require racket/list
         racket/math
         "measurement-interpolation.rkt"
         "nec2c.rkt")

(provide
 gain-at maximum-gain maximum-gain-direction
 maximum-gain-at-frequency realized-maximum-gain-at-frequency
 horizon-gain-at-frequency realized-horizon-gain-at-frequency
 maximum-gain-direction-at-frequency radiation-pattern-at-frequency
 front-to-back-ratio front-to-side-ratio
 axial-ratio-at polarization-tilt-at polarization-sense-at e-field-at
 pattern-angular-resolution measurement-pattern-frequencies)

(define (pattern-samples who pattern)
  (cond
    [(nec2c-pattern? pattern) (nec2c-pattern-samples pattern)]
    [(nec2c-pattern-grid? pattern) (nec2c-pattern-grid-samples pattern)]
    [else
     (raise-argument-error
      who "(or/c nec2c-pattern? nec2c-pattern-grid?)" pattern)]))

(define (gain-accessor who component)
  (case component
    [(total) nec2c-pattern-sample-total-gain-db]
    [(vertical) nec2c-pattern-sample-vertical-gain-db]
    [(horizontal) nec2c-pattern-sample-horizontal-gain-db]
    [else
     (raise-arguments-error who
                            "unknown gain component"
                            "component" component
                            "expected" '(total vertical horizontal))]))

(define (sample-azimuth sample)
  (normalize-azimuth (nec2c-pattern-sample-azimuth-deg sample)))

(define (sample-elevation sample)
  (nec2c-pattern-sample-elevation-deg sample))

(define (angle-exact? sample azimuth elevation)
  (and (approximately=?
        (min (abs (- (sample-azimuth sample) azimuth))
             (- 360.0 (abs (- (sample-azimuth sample) azimuth))))
        0.0)
       (approximately=? (sample-elevation sample) elevation)))

(define (unique-sorted numbers)
  (sort (remove-duplicates numbers approximately=?) <))

(define (bracket-linear who coordinates target label)
  (define exact
    (findf (lambda (value) (approximately=? value target)) coordinates))
  (cond
    [exact (values exact exact 0.0)]
    [else
     (define lower (for/fold ([candidate #f]) ([value (in-list coordinates)]
                                                   #:when (< value target))
                     value))
     (define upper
       (findf (lambda (value) (> value target)) coordinates))
     (unless (and lower upper)
       (raise-arguments-error who
                              "cannot extrapolate beyond the sampled angular range"
                              label target
                              "available" coordinates))
     (values lower upper (/ (- target lower) (- upper lower)))]))

(define (bracket-azimuth who coordinates target)
  (define normalized (normalize-azimuth target))
  (define exact
    (findf (lambda (value) (approximately=? value normalized)) coordinates))
  (cond
    [exact (values exact exact 0.0)]
    [else
     (when (= (length coordinates) 1)
       (raise-arguments-error
        who "cannot interpolate an azimuth from a single sampled bearing"
        "requested azimuth (degrees)" target
        "available azimuth (degrees)" (first coordinates)))
     (define extended
       (sort (append coordinates
                     (map (lambda (value) (+ value 360.0)) coordinates))
             <))
     (define adjusted
       (if (< normalized (first coordinates)) (+ normalized 360.0) normalized))
     (define lower
       (for/fold ([candidate #f]) ([value (in-list extended)]
                                   #:when (< value adjusted))
         value))
     (define upper (findf (lambda (value) (> value adjusted)) extended))
     (values (normalize-azimuth lower)
             (normalize-azimuth upper)
             (/ (- adjusted lower) (- upper lower)))]))

(define (sample-at-angle samples azimuth elevation)
  (findf (lambda (sample) (angle-exact? sample azimuth elevation)) samples))

(define (interpolated-pattern-value who samples azimuth elevation accessor
                                    interpolator interpolate?)
  (define az (normalize-azimuth azimuth))
  (define exact (sample-at-angle samples az elevation))
  (cond
    [exact (accessor exact)]
    [(not interpolate?)
     (raise-arguments-error
      who
      "no pattern sample exists at the requested direction; enable interpolation or choose a sampled direction"
      "azimuth (degrees)" azimuth
      "elevation (degrees)" elevation)]
    [else
     (define azimuths (unique-sorted (map sample-azimuth samples)))
     (define elevations (unique-sorted (map sample-elevation samples)))
     (define-values (az0 az1 az-fraction) (bracket-azimuth who azimuths az))
     (define-values (el0 el1 el-fraction)
       (bracket-linear who elevations elevation "elevation (degrees)"))
     (define corners
       (for*/list ([corner-el (in-list (remove-duplicates (list el0 el1)))]
                    [corner-az (in-list (remove-duplicates (list az0 az1)))])
         (sample-at-angle samples corner-az corner-el)))
     (define (at corner-az corner-el)
       (define value (accessor (sample-at-angle samples corner-az corner-el)))
       (if value
           value
           (raise-arguments-error who
                                  "the requested measurement is unavailable at a grid corner"
                                  "azimuth (degrees)" corner-az
                                  "elevation (degrees)" corner-el)))
     (cond
       [(andmap values corners)
        (define low (interpolator (at az0 el0) (at az1 el0) az-fraction))
        (define high (interpolator (at az0 el1) (at az1 el1) az-fraction))
        (interpolator low high el-fraction)]
       [else
        ;; A pattern cut has only one angular dimension. Accept interpolation
        ;; along a sampled row or column without pretending that it is a grid.
        (define same-elevation
          (filter (lambda (sample)
                    (approximately=? (sample-elevation sample) elevation))
                  samples))
        (define same-azimuth
          (filter (lambda (sample)
                    (approximately=? (sample-azimuth sample) az))
                  samples))
        (cond
          [(>= (length same-elevation) 2)
           (define row-azimuths
             (unique-sorted (map sample-azimuth same-elevation)))
           (define-values (row0 row1 row-fraction)
             (bracket-azimuth who row-azimuths az))
           (interpolator (at row0 elevation) (at row1 elevation)
                         row-fraction)]
          [(>= (length same-azimuth) 2)
           (define column-elevations
             (unique-sorted (map sample-elevation same-azimuth)))
           (define-values (column0 column1 column-fraction)
             (bracket-linear who column-elevations elevation
                             "elevation (degrees)"))
           (interpolator (at az column0) (at az column1)
                         column-fraction)]
          [else
           (raise-arguments-error
            who
            "the available pattern does not bracket the requested direction"
            "azimuth (degrees)" azimuth
            "elevation (degrees)" elevation)])])]))

(define (gain-at pattern #:azimuth azimuth #:elevation elevation
                 #:component [component 'total]
                 #:interpolate? [interpolate? #t])
  (interpolated-pattern-value
   'gain-at (pattern-samples 'gain-at pattern) azimuth elevation
   (gain-accessor 'gain-at component) interpolate-db-power interpolate?))

(define (available-gain-samples who pattern component)
  (define accessor (gain-accessor who component))
  (filter (lambda (sample) (real? (accessor sample)))
          (pattern-samples who pattern)))

(define (maximum-gain-sample who pattern component)
  (define accessor (gain-accessor who component))
  (define samples (available-gain-samples who pattern component))
  (when (null? samples)
    (raise-arguments-error who "the pattern has no gain samples"))
  (argmax accessor samples))

(define (maximum-gain pattern #:component [component 'total])
  ((gain-accessor 'maximum-gain component)
   (maximum-gain-sample 'maximum-gain pattern component)))

(define (maximum-gain-direction pattern #:component [component 'total])
  (define sample
    (maximum-gain-sample 'maximum-gain-direction pattern component))
  (list (sample-azimuth sample) (sample-elevation sample)))

(define (gain-sweep-value-at who result frequency accessor interpolate?)
  (unless (nec2c-gain-sweep-result? result)
    (raise-argument-error who "nec2c-gain-sweep-result?" result))
  (sample-at-frequency
   who
   (nec2c-gain-sweep-result-samples result)
   frequency
   nec2c-gain-sweep-sample-frequency-mhz
   accessor
   interpolate-db-power
   interpolate?))

(define (maximum-gain-at-frequency result frequency
                                   #:interpolate? [interpolate? #t])
  (gain-sweep-value-at
   'maximum-gain-at-frequency result frequency
   nec2c-gain-sweep-sample-maximum-gain-db interpolate?))

(define (realized-maximum-gain-at-frequency
         result frequency #:interpolate? [interpolate? #t])
  (gain-sweep-value-at
   'realized-maximum-gain-at-frequency result frequency
   nec2c-gain-sweep-sample-realized-maximum-gain-db interpolate?))

(define (horizon-gain-at-frequency result frequency
                                   #:interpolate? [interpolate? #t])
  (gain-sweep-value-at
   'horizon-gain-at-frequency result frequency
   nec2c-gain-sweep-sample-horizon-gain-db interpolate?))

(define (realized-horizon-gain-at-frequency
         result frequency #:interpolate? [interpolate? #t])
  (gain-sweep-value-at
   'realized-horizon-gain-at-frequency result frequency
   nec2c-gain-sweep-sample-realized-horizon-gain-db interpolate?))

(define (gain-sweep-discrete-value-at who result frequency accessor)
  (unless (nec2c-gain-sweep-result? result)
    (raise-argument-error who "nec2c-gain-sweep-result?" result))
  (sample-at-frequency
   who
   (nec2c-gain-sweep-result-samples result)
   frequency
   nec2c-gain-sweep-sample-frequency-mhz
   accessor
   (lambda (left _right _fraction) left)
   #f))

(define (maximum-gain-direction-at-frequency result frequency)
  (gain-sweep-discrete-value-at
   'maximum-gain-direction-at-frequency result frequency
   nec2c-gain-sweep-sample-maximum-gain-direction))

(define (radiation-pattern-at-frequency result frequency)
  (gain-sweep-discrete-value-at
   'radiation-pattern-at-frequency result frequency
   nec2c-gain-sweep-sample-pattern))

(define (front-to-back-ratio pattern #:component [component 'total]
                             #:interpolate? [interpolate? #t])
  (define front (maximum-gain-sample 'front-to-back-ratio pattern component))
  (define front-gain ((gain-accessor 'front-to-back-ratio component) front))
  (- front-gain
     (gain-at pattern
              #:azimuth (+ (sample-azimuth front) 180.0)
              #:elevation (sample-elevation front)
              #:component component
              #:interpolate? interpolate?)))

(define (minimum-positive-step values [period #f])
  (define ordered (unique-sorted values))
  (define differences
    (for/list ([left (in-list ordered)] [right (in-list (rest ordered))]
               #:when (not (approximately=? left right)))
      (- right left)))
  (define with-wrap
    (if (and period (> (length ordered) 1))
        (cons (- (+ (first ordered) period) (last ordered)) differences)
        differences))
  (and (pair? with-wrap) (apply min with-wrap)))

(define (front-to-side-ratio pattern #:component [component 'total])
  (define who 'front-to-side-ratio)
  (unless (nec2c-pattern-grid? pattern)
    (raise-argument-error who "nec2c-pattern-grid?" pattern))
  (define accessor (gain-accessor who component))
  (define front (maximum-gain-sample who pattern component))
  (define resolution (pattern-angular-resolution pattern))
  (define step
    (max 1.0 (min 10.0 (or (first resolution) (second resolution) 5.0))))
  (define front-az (* (sample-azimuth front) (/ pi 180.0)))
  (define front-el (* (sample-elevation front) (/ pi 180.0)))
  (define front-vector
    (vector (* (cos front-el) (cos front-az))
            (* (cos front-el) (sin front-az))
            (sin front-el)))
  ;; U is horizontal and perpendicular to the main beam. V completes an
  ;; orthonormal basis for the great circle 90 degrees away from the beam.
  (define u (vector (- (vector-ref front-vector 1))
                    (vector-ref front-vector 0)
                    0.0))
  (define u-length
    (sqrt (+ (sqr (vector-ref u 0)) (sqr (vector-ref u 1)))))
  (define unit-u
    (if (< u-length 1e-12)
        (vector 1.0 0.0 0.0)
        (vector (/ (vector-ref u 0) u-length)
                (/ (vector-ref u 1) u-length)
                0.0)))
  (define unit-v
    (vector (- (* (vector-ref front-vector 1) (vector-ref unit-u 2))
               (* (vector-ref front-vector 2) (vector-ref unit-u 1)))
            (- (* (vector-ref front-vector 2) (vector-ref unit-u 0))
               (* (vector-ref front-vector 0) (vector-ref unit-u 2)))
            (- (* (vector-ref front-vector 0) (vector-ref unit-u 1))
               (* (vector-ref front-vector 1) (vector-ref unit-u 0)))))
  (define side-gains
    (filter
     real?
     (for/list ([circle-angle (in-range 0.0 360.0 step)])
       (define radians (* circle-angle (/ pi 180.0)))
       (define direction
         (for/vector ([left (in-vector unit-u)] [right (in-vector unit-v)])
           (+ (* (cos radians) left) (* (sin radians) right))))
       (define azimuth
         (normalize-azimuth
          (* (atan (vector-ref direction 1) (vector-ref direction 0))
             (/ 180.0 pi))))
       (define elevation
         (* (asin (max -1.0 (min 1.0 (vector-ref direction 2))))
            (/ 180.0 pi)))
       (with-handlers ([exn:fail:contract? (lambda (_failure) #f)])
         (gain-at pattern #:azimuth azimuth #:elevation elevation
                  #:component component #:interpolate? #t)))))
  (when (null? side-gains)
    (raise-arguments-error
     who
     "the sampled pattern has no directions on the 90-degree side circle"))
  (- (accessor front) (apply max side-gains)))

(define (ordinary-pattern-value who pattern azimuth elevation accessor
                                interpolate? [interpolator interpolate-number])
  (interpolated-pattern-value
   who (pattern-samples who pattern) azimuth elevation accessor interpolator
   interpolate?))

(define (axial-ratio-at pattern #:azimuth azimuth #:elevation elevation
                        #:interpolate? [interpolate? #t])
  (ordinary-pattern-value
   'axial-ratio-at pattern azimuth elevation
   nec2c-pattern-sample-axial-ratio interpolate?))

(define (polarization-tilt-at pattern #:azimuth azimuth #:elevation elevation
                              #:interpolate? [interpolate? #t])
  (ordinary-pattern-value
   'polarization-tilt-at pattern azimuth elevation
   nec2c-pattern-sample-tilt-deg interpolate?))

(define (polarization-sense-at pattern #:azimuth azimuth #:elevation elevation)
  (ordinary-pattern-value
   'polarization-sense-at pattern azimuth elevation
   nec2c-pattern-sample-polarization-sense #f
   (lambda (left _right _fraction) left)))

(define (e-field-at pattern #:azimuth azimuth #:elevation elevation
                    #:interpolate? [interpolate? #t])
  (values
   (ordinary-pattern-value
    'e-field-at pattern azimuth elevation
    nec2c-pattern-sample-e-theta interpolate? interpolate-complex)
   (ordinary-pattern-value
    'e-field-at pattern azimuth elevation
    nec2c-pattern-sample-e-phi interpolate? interpolate-complex)))

(define (pattern-angular-resolution pattern)
  (define samples (pattern-samples 'pattern-angular-resolution pattern))
  (list
   (minimum-positive-step (map sample-azimuth samples) 360.0)
   (minimum-positive-step (map sample-elevation samples))))

(define (measurement-pattern-frequencies pattern)
  (if (nec2c-gain-sweep-result? pattern)
      (map nec2c-gain-sweep-sample-frequency-mhz
           (nec2c-gain-sweep-result-samples pattern))
      (unique-sorted
       (map nec2c-pattern-sample-frequency-mhz
            (pattern-samples 'measurement-frequencies pattern)))))
