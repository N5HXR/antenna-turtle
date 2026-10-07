#lang racket/base

(require racket/list
         racket/math
         racket/runtime-path
         plot/no-gui
         "plot-cursor.rkt"
         "radiation-case.rkt"
         "visualization-handle.rkt"
         "nec2c.rkt")

(provide
 vswr-sweep-renderers
 return-loss-sweep-renderers
 impedance-sweep-renderers
 smith-chart-renderers
 radiation-cut-renderers
 radiation-grid-renderers
 show-vswr-sweep
 show-return-loss-sweep
 show-impedance-sweep
 show-smith-chart
 show-radiation-cut
 show-radiation-pattern-3d
 show-radiation-pattern-opengl
 show-radiation-comparison
 visualization-handle?
 visualization-update!
 visualization-show!
 visualization-close!
 visualization-open?
 (struct-out radiation-case))

(define colors
  '("steelblue" "firebrick" "darkgreen" "darkorange" "purple" "teal"))

(define-runtime-path proportional-plot3d-path "proportional-plot3d.rkt")
(define-runtime-path opengl-view-path "nec2c-opengl-view.rkt")
(define-runtime-path interactive-plot-path "interactive-plot.rkt")

(define (color-at index)
  (list-ref colors (modulo index (length colors))))

(define (sweep-feed-names result)
  (remove-duplicates
   (for*/list ([frequency (in-list (nec2c-sweep-result-frequencies result))]
               [sample (in-list (nec2c-sweep-frequency-feed-samples frequency))])
     (nec2c-feedpoint-sample-feed-name
      (nec2c-sweep-sample-feedpoint sample)))))

(define (samples-for-feed result name)
  (for*/list ([frequency (in-list (nec2c-sweep-result-frequencies result))]
              [sample (in-list (nec2c-sweep-frequency-feed-samples frequency))]
              #:when (string=?
                      name
                      (nec2c-feedpoint-sample-feed-name
                       (nec2c-sweep-sample-feedpoint sample))))
    sample))

(define (vswr-points result name max-vswr)
  (for/list ([sample (in-list (samples-for-feed result name))])
    (define feedpoint (nec2c-sweep-sample-feedpoint sample))
    (define vswr (nec2c-sweep-sample-vswr sample))
    (vector (nec2c-feedpoint-sample-frequency-mhz feedpoint)
            (cond [max-vswr (min max-vswr vswr)]
                  ;; Plot treats a NaN point as a break in the line. An
                  ;; infinite VSWR therefore remains present in the data
                  ;; result without forcing an impossible finite axis.
                  [(rational? vswr) vswr]
                  [else +nan.0]))))

(define (vswr-cursor-series result max-vswr)
  (for/list ([name (in-list (sweep-feed-names result))]
             [index (in-naturals)])
    (cursor-series name
                   (vswr-points result name max-vswr)
                   (color-at index))))

(define (vswr-sweep-renderers result #:max-vswr [max-vswr #f])
  (unless (nec2c-sweep-result? result)
    (raise-argument-error 'vswr-sweep-renderers "nec2c-sweep-result?" result))
  (unless (or (not max-vswr)
              (and (rational? max-vswr) (> max-vswr 1)))
    (raise-argument-error
     'vswr-sweep-renderers "(or/c #f (and/c rational? (>/c 1)))" max-vswr))
  (append
   (for/list ([series (in-list (vswr-cursor-series result max-vswr))])
     (lines (cursor-series-points series)
      #:color (cursor-series-color series)
      #:width 2
      #:label (cursor-series-label series)))
   (list (hrule 2 #:style 'short-dash #:color "gray" #:label "2:1")
         (hrule 3 #:style 'dot #:color "darkgray" #:label "3:1"))))

(define (return-loss-points result name floor-db)
  (for/list ([sample (in-list (samples-for-feed result name))])
    (define feedpoint (nec2c-sweep-sample-feedpoint sample))
    (define return-loss (nec2c-sweep-sample-return-loss-db sample))
    (vector
     (nec2c-feedpoint-sample-frequency-mhz feedpoint)
     (cond [floor-db (max floor-db (- return-loss))]
           ;; The data object retains conventional positive return loss.
           ;; Plot its negative, 20 log10 |Gamma|, so a good match is the
           ;; familiar downward S11 dip. Break an exact-match infinity in
           ;; an uncapped line so it cannot force a non-finite axis.
           [(rational? return-loss) (- return-loss)]
           [else +nan.0]))))

(define (return-loss-cursor-series result floor-db)
  (for/list ([name (in-list (sweep-feed-names result))]
             [index (in-naturals)])
    (cursor-series name
                   (return-loss-points result name floor-db)
                   (color-at index))))

(define (return-loss-sweep-renderers
         result
         #:floor-db [floor-db #f])
  (unless (nec2c-sweep-result? result)
    (raise-argument-error
     'return-loss-sweep-renderers "nec2c-sweep-result?" result))
  (unless (or (not floor-db)
              (and (rational? floor-db) (negative? floor-db)))
    (raise-argument-error
     'return-loss-sweep-renderers
     "(or/c #f negative-rational?)"
     floor-db))
  (append
   (for/list ([series (in-list
                       (return-loss-cursor-series result floor-db))])
     (lines (cursor-series-points series)
      #:color (cursor-series-color series)
      #:width 2
      #:label (cursor-series-label series)))
   (list (hrule -10
                #:style 'short-dash
                #:color "gray"
                #:label "-10 dB"))))

(define (impedance-cursor-series result)
  (append*
   (for/list ([name (in-list (sweep-feed-names result))]
              [index (in-naturals)])
     (define samples (samples-for-feed result name))
     (define color (color-at index))
     (define (points part)
       (for/list ([sample (in-list samples)])
         (define feedpoint (nec2c-sweep-sample-feedpoint sample))
         (vector (nec2c-feedpoint-sample-frequency-mhz feedpoint)
                 (part (nec2c-feedpoint-sample-impedance feedpoint)))))
     (list (cursor-series (format "~a R" name) (points real-part) color)
           (cursor-series (format "~a X" name) (points imag-part) color)))))

(define (impedance-sweep-renderers result)
  (unless (nec2c-sweep-result? result)
    (raise-argument-error
     'impedance-sweep-renderers "nec2c-sweep-result?" result))
  (append*
   (for/list ([series (in-list (impedance-cursor-series result))]
              [index (in-naturals)])
     (list
      (lines (cursor-series-points series)
             #:color (cursor-series-color series)
             #:style (if (odd? index) 'short-dash 'solid)
             #:width 2
             #:label (cursor-series-label series))))))

;; Smith charts use normalized impedance z = Z/Z0 and plot the reflection
;; coefficient Gamma = (z - 1)/(z + 1). Passive impedances lie on or inside
;; the unit circle; active or otherwise impossible values are deliberately
;; broken out of the trace rather than changing the familiar chart geometry.
(define smith-major-resistances '(0 0.2 0.5 1 2 5))
(define smith-minor-resistances '(0.1 0.3 0.4 0.6 0.8 1.5 3 4 10))
(define smith-major-reactances '(0.2 0.5 1 2 5))
(define smith-minor-reactances '(0.1 0.3 0.4 0.6 0.8 1.5 3 4 10))

(define (validate-smith-options who markers? theme)
  (unless (boolean? markers?)
    (raise-argument-error who "boolean?" markers?))
  (unless (memq theme '(light dark))
    (raise-argument-error who "(or/c 'light 'dark)" theme)))

(define (smith-theme theme)
  (if (eq? theme 'dark)
      (hash 'background "black"
            'foreground "white"
            'boundary '(150 150 150)
            'major '(92 92 92)
            'minor '(48 48 48)
            'vswr-15 '(190 190 190)
            'vswr-20 '(130 130 130))
      (hash 'background "white"
            'foreground "black"
            'boundary '(70 70 70)
            'major '(150 150 150)
            'minor '(215 215 215)
            'vswr-15 '(85 85 85)
            'vswr-20 '(130 130 130))))

(define (normalized-impedance->gamma resistance reactance)
  (/ (- (make-rectangular resistance reactance) 1)
     (+ (make-rectangular resistance reactance) 1)))

(define (complex->point value)
  (vector (real-part value) (imag-part value)))

(define (smith-circle-points center radius [samples 240])
  (for/list ([index (in-range (add1 samples))])
    (define angle (* 2 pi (/ index samples)))
    (vector (+ center (* radius (cos angle)))
            (* radius (sin angle)))))

(define (smith-resistance-points resistance)
  (define denominator (+ resistance 1))
  (smith-circle-points (/ resistance denominator) (/ 1 denominator)))

(define (smith-reactance-points reactance [samples 180])
  (for/list ([index (in-range (add1 samples))])
    (if (= index samples)
        (vector 1 0)
        (let* ([parameter (/ index samples)]
               [resistance (/ parameter (- 1 parameter))])
          (complex->point
           (normalized-impedance->gamma resistance reactance))))))

(define (smith-grid-renderers theme)
  (define colors (smith-theme theme))
  (define minor-color (hash-ref colors 'minor))
  (define major-color (hash-ref colors 'major))
  (define foreground (hash-ref colors 'foreground))
  (define (resistance-lines values color width)
    (for/list ([resistance (in-list values)])
      (lines (smith-resistance-points resistance)
             #:color color #:width width)))
  (define (reactance-lines values color width)
    (append*
     (for/list ([reactance (in-list values)])
       (list (lines (smith-reactance-points reactance)
                    #:color color #:width width)
             (lines (smith-reactance-points (- reactance))
                    #:color color #:width width)))))
  (define resistance-labels
    (for/list ([resistance (in-list smith-major-resistances)])
      (define gamma (normalized-impedance->gamma resistance 0))
      (point-label (complex->point gamma)
                   (format "~a" resistance)
                   #:color foreground
                   #:size 9
                   #:anchor 'bottom
                   #:point-size 0)))
  (define reactance-labels
    (append*
     (for/list ([reactance (in-list smith-major-reactances)])
       (define positive
         (normalized-impedance->gamma 0 reactance))
       (define negative
         (normalized-impedance->gamma 0 (- reactance)))
       (list
        (point-label (complex->point positive)
                     (format "+j~a" reactance)
                     #:color foreground #:size 8 #:anchor 'auto #:point-size 0)
        (point-label (complex->point negative)
                     (format "-j~a" reactance)
                     #:color foreground #:size 8 #:anchor 'auto #:point-size 0)))))
  (append
   (resistance-lines smith-minor-resistances minor-color 0.35)
   (reactance-lines smith-minor-reactances minor-color 0.35)
   (resistance-lines smith-major-resistances major-color 0.7)
   (reactance-lines smith-major-reactances major-color 0.7)
   (list
    (lines (list (vector -1 0) (vector 1 0))
           #:color major-color #:width 0.7)
    (lines (smith-circle-points 0 1)
           #:color (hash-ref colors 'boundary) #:width 1.2)
    (lines (smith-circle-points 0 (/ (- 1.5 1) (+ 1.5 1)))
           #:color (hash-ref colors 'vswr-15)
           #:width 0.8 #:style 'short-dash #:label "1.5:1 VSWR")
    (lines (smith-circle-points 0 (/ (- 2 1) (+ 2 1)))
           #:color (hash-ref colors 'vswr-20)
           #:width 0.8 #:style 'long-dash #:label "2.0:1 VSWR"))
   resistance-labels
   reactance-labels))

(define (passive-gamma? gamma)
  (and (number? gamma)
       (rational? (real-part gamma))
       (rational? (imag-part gamma))
       (<= (magnitude gamma) (+ 1 1e-9))))

(define (smith-sample-point sample)
  (define feedpoint (nec2c-sweep-sample-feedpoint sample))
  (define gamma (nec2c-sweep-sample-reflection-coefficient sample))
  (if (passive-gamma? gamma)
      (let ([impedance (nec2c-feedpoint-sample-impedance feedpoint)])
        (vector (real-part gamma)
                (imag-part gamma)
                (nec2c-feedpoint-sample-frequency-mhz feedpoint)
                (real-part impedance)
                (imag-part impedance)
                (- (nec2c-sweep-sample-return-loss-db sample))
                (nec2c-sweep-sample-vswr sample)))
      ;; NaN causes Plot to break the line and is ignored by the data cursor.
      (vector +nan.0 +nan.0 0 0 0 0 0)))

(define (smith-cursor-series result)
  (for/list ([name (in-list (sweep-feed-names result))]
             [index (in-naturals)])
    (cursor-series
     name
     (for/list ([sample (in-list (samples-for-feed result name))])
       (smith-sample-point sample))
     (color-at index))))

(define (finite-smith-point? point)
  (and (rational? (vector-ref point 0))
       (rational? (vector-ref point 1))))

(define (smith-marker-renderers series theme)
  (define points* (filter finite-smith-point? (cursor-series-points series)))
  (if (null? points*)
      '()
      (let* ([color (cursor-series-color series)]
             [background (hash-ref (smith-theme theme) 'background)]
             [start (first points*)]
             [end (last points*)]
             [best (argmin (lambda (point) (vector-ref point 6)) points*)])
        (list
         (points (list start) #:sym 'fulltriangleright
                 #:color color #:size 10 #:line-width 1.2)
         (points (list end) #:sym 'fullcircle
                 #:color color #:size 8 #:line-width 1.2)
         (points (list best) #:sym 'circle5
                 #:color color #:fill-color background
                 #:size 10 #:line-width 1.8)))))

(define (smith-chart-renderers result
                               #:markers? [markers? #t]
                               #:theme [theme 'light])
  (unless (nec2c-sweep-result? result)
    (raise-argument-error 'smith-chart-renderers "nec2c-sweep-result?" result))
  (validate-smith-options 'smith-chart-renderers markers? theme)
  (define series-list (smith-cursor-series result))
  (append
   (smith-grid-renderers theme)
   (for/list ([series (in-list series-list)])
     (lines (cursor-series-points series)
            #:color (cursor-series-color series)
            #:width 2
            #:label (cursor-series-label series)))
   (if markers?
       (append*
        (for/list ([series (in-list series-list)])
          (smith-marker-renderers series theme)))
       '())))

(define (sample-gain sample component)
  (case component
    [(total) (nec2c-pattern-sample-total-gain-db sample)]
    [(vertical) (nec2c-pattern-sample-vertical-gain-db sample)]
    [(horizontal) (nec2c-pattern-sample-horizontal-gain-db sample)]
    [else
     (raise-argument-error
      'radiation-pattern "(or/c 'total 'vertical 'horizontal)" component)]))

(define (pattern-angle pattern sample)
  (case (nec2c-pattern-kind pattern)
    [(azimuth) (nec2c-pattern-sample-azimuth-deg sample)]
    [(elevation)
     (define fixed (nec2c-pattern-fixed-angle pattern))
     (define sample-azimuth (nec2c-pattern-sample-azimuth-deg sample))
     (if (< (abs (- sample-azimuth fixed)) 1e-6)
         (nec2c-pattern-sample-elevation-deg sample)
         (- 180 (nec2c-pattern-sample-elevation-deg sample)))]
    [else (error 'radiation-cut-renderers "unknown pattern kind")]))

(define (gain-transform gains floor-db normalize?)
  (define available (filter real? gains))
  (when (null? available)
    (error 'radiation-pattern "selected gain component has no samples"))
  (define peak (apply max available))
  (lambda (gain)
    (and (real? gain)
         (- (max floor-db (if normalize? (- gain peak) gain)) floor-db))))

(define (radiation-cut-cursor-points pattern component floor-db normalize?)
  (define samples (nec2c-pattern-samples pattern))
  (define transform
    (gain-transform (map (lambda (sample) (sample-gain sample component)) samples)
                    floor-db normalize?))
  (filter
   values
   (for/list ([sample (in-list samples)])
     (define gain (sample-gain sample component))
     (define radius (transform gain))
     (and radius
          (let* ([angle-degrees (pattern-angle pattern sample)]
                 [angle (degrees->radians angle-degrees)])
            ;; The extra elements are retained for precise data-tip labels;
            ;; Plot renderers consume only the first two coordinates below.
            (vector (* radius (cos angle)) (* radius (sin angle))
                    angle-degrees gain))))))

(define (radiation-cut-renderers pattern
                                 #:component [component 'total]
                                 #:floor-db [floor-db -40]
                                 #:normalize? [normalize? #t])
  (unless (nec2c-pattern? pattern)
    (raise-argument-error 'radiation-cut-renderers "nec2c-pattern?" pattern))
  (unless (and (real? floor-db) (< floor-db 0))
    (raise-argument-error 'radiation-cut-renderers "negative-real?" floor-db))
  (define points
    (radiation-cut-cursor-points pattern component floor-db normalize?))
  (list (polar-axes)
        (lines (for/list ([point (in-list points)])
                 (vector (vector-ref point 0) (vector-ref point 1)))
               #:color "steelblue" #:width 2
               #:label (symbol->string component))))

(define (angle-key theta phi)
  (cons (inexact->exact (round (* theta 1000000)))
        (inexact->exact (round (* phi 1000000)))))

(define (spherical-point theta-deg phi-deg radius)
  (define theta (degrees->radians theta-deg))
  (define phi (degrees->radians phi-deg))
  (define horizontal (* radius (sin theta)))
  (vector (* horizontal (cos phi))
          (* horizontal (sin phi))
          (* radius (cos theta))))

;; NEC2C can profitably calculate a much finer angular grid than Plot3D can
;; profitably draw as thousands of independently colored polygons. Keep the
;; analysis samples intact, but select an existing subset for display. The
;; open variant preserves both poles; the cyclic variant leaves the seam to
;; the renderer, which connects its last value back to its first value.
(define (sample-open-angle-values values minimum-step)
  (cond
    [(<= (length values) 2) values]
    [else
     (define first-value (first values))
     (define last-value (last values))
     (define selected-reversed (list first-value))
     (define previous first-value)
     (for ([value (in-list (drop-right (rest values) 1))])
       (when (>= (- value previous) minimum-step)
         (set! selected-reversed (cons value selected-reversed))
         (set! previous value)))
     (reverse (cons last-value selected-reversed))]))

(define (sample-cyclic-angle-values values minimum-step)
  (cond
    [(<= (length values) 1) values]
    [else
     (define first-value (first values))
     (define selected-reversed (list first-value))
     (define previous first-value)
     (for ([value (in-list (rest values))])
       (when (>= (- value previous) minimum-step)
         (set! selected-reversed (cons value selected-reversed))
         (set! previous value)))
     (reverse selected-reversed)]))

(define (radiation-grid-renderers grid
                                  #:component [component 'total]
                                  #:floor-db [floor-db -40]
                                  #:normalize? [normalize? #t]
                                  #:mesh-step [mesh-step 5])
  (unless (nec2c-pattern-grid? grid)
    (raise-argument-error
     'radiation-grid-renderers "nec2c-pattern-grid?" grid))
  (define samples (nec2c-pattern-grid-samples grid))
  (define available-gains
    (filter real?
            (map (lambda (sample) (sample-gain sample component)) samples)))
  (when (null? available-gains)
    (error 'radiation-grid-renderers
           "selected gain component has no samples"))
  (define transform
    (gain-transform (map (lambda (sample) (sample-gain sample component)) samples)
                    floor-db normalize?))
  (define table (make-hash))
  (for ([sample (in-list samples)])
    (hash-set! table
               (angle-key (nec2c-pattern-sample-theta-deg sample)
                          (nec2c-pattern-sample-phi-deg sample))
               sample))
  (unless (and (real? mesh-step) (positive? mesh-step))
    (raise-argument-error 'radiation-grid-renderers "positive-real?" mesh-step))
  (define theta-values
    (sample-open-angle-values
     (nec2c-pattern-grid-theta-values grid) mesh-step))
  (define phi-values
    (sample-cyclic-angle-values
     (nec2c-pattern-grid-phi-values grid) mesh-step))
  (define (grid-sample theta phi)
    (define normalized-phi
      (- phi (* 360 (floor (/ phi 360)))))
    (hash-ref table (angle-key theta normalized-phi)))
  (define (sample-radius sample)
    (or (transform (sample-gain sample component)) 0))
  ;; Precompute the Plot3D polygons once. The former colorized renderer did
  ;; hash lookups, trigonometry, color interpolation, and polygon allocation
  ;; during every repaint; that made mouse rotation take seconds per frame.
  ;; This deliberately simple renderer is the responsive Plot3D baseline.
  (define surface-polygons
    (for*/list ([theta-index (in-range (sub1 (length theta-values)))]
                [phi-index (in-range (length phi-values))])
      (define theta-a (list-ref theta-values theta-index))
      (define theta-b (list-ref theta-values (add1 theta-index)))
      (define phi-a (list-ref phi-values phi-index))
      (define phi-b
        (if (= phi-index (sub1 (length phi-values)))
            (+ 360 (first phi-values))
            (list-ref phi-values (add1 phi-index))))
      (define face-samples
        (list (grid-sample theta-a phi-a)
              (grid-sample theta-a phi-b)
              (grid-sample theta-b phi-b)
              (grid-sample theta-b phi-a)))
      (define radii (map sample-radius face-samples))
      (cond
          ;; At either pole, the first two or last two nominal vertices are
          ;; coincident. Sending those zero-area quads through Plot3D's BSP
          ;; sorter can cause pathological recursion on a fine grid. A single
          ;; shared pole and a triangle describe the same surface cleanly.
          [(zero? theta-a)
           (list (spherical-point
                  theta-a phi-a (/ (+ (list-ref radii 0)
                                      (list-ref radii 1)) 2))
                 (spherical-point theta-b phi-b (list-ref radii 2))
                 (spherical-point theta-b phi-a (list-ref radii 3)))]
          [(= theta-b 180)
           (list (spherical-point theta-a phi-a (list-ref radii 0))
                 (spherical-point theta-a phi-b (list-ref radii 1))
                 (spherical-point
                  theta-b phi-a (/ (+ (list-ref radii 2)
                                      (list-ref radii 3)) 2)))]
        [else
           (list (spherical-point theta-a phi-a (list-ref radii 0))
                 (spherical-point theta-a phi-b (list-ref radii 1))
                 (spherical-point theta-b phi-b (list-ref radii 2))
                 (spherical-point theta-b phi-a (list-ref radii 3)))])))
  (define cap-polygons
    (if (and (pair? theta-values)
             (< (abs (- (last theta-values) 90)) 1e-6))
        (let ([theta (last theta-values)])
          (for/list ([phi-index (in-range (length phi-values))])
            (define phi-a (list-ref phi-values phi-index))
            (define phi-b
              (if (= phi-index (sub1 (length phi-values)))
                  (+ 360 (first phi-values))
                  (list-ref phi-values (add1 phi-index))))
            (list (vector 0 0 0)
                  (spherical-point
                   theta phi-b (sample-radius (grid-sample theta phi-b)))
                  (spherical-point
                   theta phi-a (sample-radius (grid-sample theta phi-a))))))
        '()))
  (define polygons (append surface-polygons cap-polygons))
  (list
   (polygons3d polygons
               #:color "steelblue"
               #:line-color "midnightblue"
               #:line-width 0.35
               #:alpha 0.92
               #:label (symbol->string component))))

(define (interactive-plot-procedure)
  (with-handlers ([exn:fail?
                   (lambda (failure)
                     (raise-user-error
                      'show-plot "could not start the Plot viewer: ~a"
                      (exn-message failure)))])
    (dynamic-require interactive-plot-path 'show-interactive-plot)))

(define (show-plot renderers series label-proc
                   #:title title #:x-label x-label #:y-label y-label
                   #:x-min [x-min #f] #:x-max [x-max #f]
                   #:y-min [y-min #f] #:y-max [y-max #f]
                   #:aspect-ratio [aspect-ratio #f]
                   #:legend-anchor [legend-anchor 'top-left]
                   #:axes? [axes? #t]
                   #:cursor-rule? [cursor-rule? #t]
                   #:theme [theme 'light])
  ((interactive-plot-procedure)
   renderers series label-proc
   #:title title #:x-label x-label #:y-label y-label
   #:x-min x-min #:x-max x-max #:y-min y-min #:y-max y-max
   #:aspect-ratio aspect-ratio
   #:legend-anchor legend-anchor
   #:axes? axes?
   #:cursor-rule? cursor-rule?
   #:theme theme))

(define (cursor-number value)
  (cond
    [(rational? value) (real->decimal-string (exact->inexact value) 4)]
    [(equal? value +inf.0) "+inf"]
    [(equal? value -inf.0) "-inf"]
    [else (format "~a" value)]))

(define (smith-impedance resistance reactance)
  (format "~a~aj~a"
          (cursor-number resistance)
          (if (negative? reactance) "-" "+")
          (cursor-number (abs reactance))))

(define (sweep-label-proc value-name value-unit)
  (lambda (series point)
    (format "~a | ~a MHz | ~a: ~a~a"
            (cursor-series-label series)
            (cursor-number (vector-ref point 0))
            value-name
            (cursor-number (vector-ref point 1))
            value-unit)))

(define (show-vswr-sweep result #:max-vswr [max-vswr #f])
  (show-plot
   (vswr-sweep-renderers result #:max-vswr max-vswr)
   (vswr-cursor-series result max-vswr)
   (sweep-label-proc "VSWR" ":1")
   #:title "NEC2C VSWR sweep"
   #:x-label "frequency (MHz)"
   #:y-label
   (format "VSWR (Z0 = ~a ohms)"
           (nec2c-sweep-result-reference-impedance result))))

(define (show-return-loss-sweep
         result
         #:floor-db [floor-db #f])
  (show-plot
   (return-loss-sweep-renderers
    result
    #:floor-db floor-db)
   (return-loss-cursor-series result floor-db)
   (sweep-label-proc "S11" " dB")
   #:title "NEC2C return-loss sweep"
   #:x-label "frequency (MHz)"
   #:y-label
   (format "return loss / S11 (dB, Z0 = ~a ohms)"
           (nec2c-sweep-result-reference-impedance result))))

(define (show-impedance-sweep result)
  (show-plot
   (impedance-sweep-renderers result)
   (impedance-cursor-series result)
   (sweep-label-proc "impedance" " ohms")
   #:title "NEC2C active impedance"
   #:x-label "frequency (MHz)"
   #:y-label "ohms"))

(define (show-smith-chart result
                          #:markers? [markers? #t]
                          #:theme [theme 'light])
  (unless (nec2c-sweep-result? result)
    (raise-argument-error 'show-smith-chart "nec2c-sweep-result?" result))
  (validate-smith-options 'show-smith-chart markers? theme)
  (show-plot
   (smith-chart-renderers result #:markers? markers? #:theme theme)
   (smith-cursor-series result)
   (lambda (series point)
     (list
      (format "~a @ ~a MHz | Z ~a ohms"
              (cursor-series-label series)
              (cursor-number (vector-ref point 2))
              (smith-impedance (vector-ref point 3) (vector-ref point 4)))
      (format "S11 ~a dB | VSWR ~a:1"
              (cursor-number (vector-ref point 5))
              (cursor-number (vector-ref point 6)))))
   #:title
   (format "NEC2C Smith chart (Z0 = ~a ohms)"
           (nec2c-sweep-result-reference-impedance result))
   #:x-label #f
   #:y-label #f
   #:x-min -1.08 #:x-max 1.08
   #:y-min -1.08 #:y-max 1.08
   #:aspect-ratio 1
   #:legend-anchor 'outside-left-top
   #:axes? #f
   #:cursor-rule? #f
   #:theme theme))

(define (show-radiation-cut pattern
                            #:component [component 'total]
                            #:floor-db [floor-db -40]
                            #:normalize? [normalize? #t])
  (show-plot
   (radiation-cut-renderers pattern
                            #:component component
                            #:floor-db floor-db
                            #:normalize? normalize?)
   (list
    (cursor-series
     (symbol->string component)
     (radiation-cut-cursor-points pattern component floor-db normalize?)
     "steelblue"))
   (lambda (series point)
     (format "~a | angle: ~a degrees | gain: ~a dBi"
             (cursor-series-label series)
             (cursor-number (vector-ref point 2))
             (cursor-number (vector-ref point 3))))
   #:title (format "NEC2C ~a pattern" (nec2c-pattern-kind pattern))
   #:x-label #f
   #:y-label #f))

(define (show-radiation-pattern-3d grid
                                   #:component [component 'total]
                                   #:floor-db [floor-db -40]
                                   #:normalize? [normalize? #t]
                                   #:mesh-step [mesh-step 5]
                                   #:aspect-ratio [aspect-ratio 1])
  (unless (nec2c-pattern-grid? grid)
    (raise-argument-error
     'show-radiation-pattern-3d "nec2c-pattern-grid?" grid))
  (unless (and (rational? aspect-ratio) (positive? aspect-ratio))
    (raise-argument-error
     'show-radiation-pattern-3d "positive-real?" aspect-ratio))
  ;; Plot3D normally normalizes each coordinate axis independently. Equal,
  ;; symmetric bounds prevent that from reshaping a directional pattern. The
  ;; proportional viewer below also changes the plot-area shape during each
  ;; rotation so horizontal and vertical screen units remain equal.
  (define gains
    (filter real?
            (map (lambda (sample) (sample-gain sample component))
                 (nec2c-pattern-grid-samples grid))))
  (when (null? gains)
    (error 'show-radiation-pattern-3d
           "selected gain component has no samples"))
  (define peak (apply max gains))
  (define radius-limit
    (max 1e-9
         (if normalize?
             (- floor-db)
             (- (max floor-db peak) floor-db))))
  (define show-proportional
    (with-handlers ([exn:fail?
                     (lambda (failure)
                       (raise-user-error
                        'show-radiation-pattern-3d
                        "could not start the proportional Plot3D viewer: ~a"
                        (exn-message failure)))])
      (dynamic-require proportional-plot3d-path
                       'show-proportional-plot3d)))
  (define arguments
    (sort
     (list (cons '#:aspect-multiplier aspect-ratio)
           (cons '#:legend-anchor 'top-left)
           (cons '#:title "NEC2C 3-D radiation pattern")
           (cons '#:x-label "x")
           (cons '#:x-min (- radius-limit))
           (cons '#:x-max radius-limit)
           (cons '#:y-label "y")
           (cons '#:y-min (- radius-limit))
           (cons '#:y-max radius-limit)
           (cons '#:z-label "z")
           (cons '#:z-min (- radius-limit))
           (cons '#:z-max radius-limit))
     keyword<? #:key car))
  (keyword-apply
   show-proportional
   (map car arguments)
   (map cdr arguments)
   (list (radiation-grid-renderers grid
                                    #:component component
                                    #:floor-db floor-db
                                    #:normalize? normalize?
                                    #:mesh-step mesh-step))))

(define (show-radiation-pattern-opengl grid
                                        #:component [component 'total]
                                        #:floor-db [floor-db -40]
                                        #:normalize? [normalize? #t]
                                        #:scale [radial-scale 'arrl]
                                        #:palette [palette 'mmana]
                                        #:color-step [color-step #f]
                                        #:mesh-step [mesh-step 2]
                                        #:axes? [axes? #t]
                                        #:antenna? [antenna? #t]
                                        #:width [width 1000]
                                        #:height [height 760])
  (define show-opengl
    (with-handlers ([exn:fail?
                     (lambda (failure)
                       (raise-user-error
                        'show-radiation-pattern-opengl
                        "could not start the OpenGL viewer: ~a"
                        (exn-message failure)))])
      (dynamic-require opengl-view-path
                       'show-radiation-pattern-opengl)))
  (show-opengl grid
               #:component component
               #:floor-db floor-db
               #:normalize? normalize?
               #:scale radial-scale
               #:palette palette
               #:color-step color-step
               #:mesh-step mesh-step
               #:axes? axes?
               #:antenna? antenna?
               #:width width
               #:height height))

(define (show-radiation-comparison cases
                                   #:component [component 'total]
                                   #:floor-db [floor-db -40]
                                   #:scale [radial-scale 'arrl]
                                   #:palette [palette 'mmana]
                                   #:color-step [color-step #f]
                                   #:mesh-step [mesh-step 2]
                                   #:aspect-ratio [aspect-ratio 16/9]
                                   #:width [width 1400])
  (define show-comparison
    (with-handlers ([exn:fail?
                     (lambda (failure)
                       (raise-user-error
                        'show-radiation-comparison
                        "could not start the OpenGL comparison viewer: ~a"
                        (exn-message failure)))])
      (dynamic-require opengl-view-path 'show-radiation-comparison)))
  (show-comparison cases
                   #:component component
                   #:floor-db floor-db
                   #:scale radial-scale
                   #:palette palette
                   #:color-step color-step
                   #:mesh-step mesh-step
                   #:aspect-ratio aspect-ratio
                   #:width width))
