#lang racket/base

(require racket/list
         racket/math
         racket/runtime-path
         plot/no-gui
         "radiation-case.rkt"
         "visualization-handle.rkt"
         "nec2c.rkt")

(provide
 vswr-sweep-renderers
 impedance-sweep-renderers
 radiation-cut-renderers
 radiation-grid-renderers
 show-vswr-sweep
 show-impedance-sweep
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

(define (vswr-sweep-renderers result #:max-vswr [max-vswr #f])
  (unless (nec2c-sweep-result? result)
    (raise-argument-error 'vswr-sweep-renderers "nec2c-sweep-result?" result))
  (unless (or (not max-vswr)
              (and (rational? max-vswr) (> max-vswr 1)))
    (raise-argument-error
     'vswr-sweep-renderers "(or/c #f (and/c rational? (>/c 1)))" max-vswr))
  (append
   (for/list ([name (in-list (sweep-feed-names result))]
              [index (in-naturals)])
     (lines
      (for/list ([sample (in-list (samples-for-feed result name))])
        (define feedpoint (nec2c-sweep-sample-feedpoint sample))
        (define vswr (nec2c-sweep-sample-vswr sample))
        (vector (nec2c-feedpoint-sample-frequency-mhz feedpoint)
                (cond [max-vswr (min max-vswr vswr)]
                      ;; Plot treats a NaN point as a break in the line. An
                      ;; infinite VSWR therefore remains present in the data
                      ;; result without forcing an impossible finite axis.
                      [(rational? vswr) vswr]
                      [else +nan.0])))
      #:color (color-at index)
      #:width 2
      #:label name))
   (list (hrule 2 #:style 'short-dash #:color "gray" #:label "2:1")
         (hrule 3 #:style 'dot #:color "darkgray" #:label "3:1"))))

(define (impedance-sweep-renderers result)
  (unless (nec2c-sweep-result? result)
    (raise-argument-error
     'impedance-sweep-renderers "nec2c-sweep-result?" result))
  (append*
   (for/list ([name (in-list (sweep-feed-names result))]
              [index (in-naturals)])
     (define samples (samples-for-feed result name))
     (define color (color-at index))
     (list
      (lines
       (for/list ([sample (in-list samples)])
         (define feedpoint (nec2c-sweep-sample-feedpoint sample))
         (vector (nec2c-feedpoint-sample-frequency-mhz feedpoint)
                 (real-part (nec2c-feedpoint-sample-impedance feedpoint))))
       #:color color #:width 2 #:label (format "~a R" name))
      (lines
       (for/list ([sample (in-list samples)])
         (define feedpoint (nec2c-sweep-sample-feedpoint sample))
         (vector (nec2c-feedpoint-sample-frequency-mhz feedpoint)
                 (imag-part (nec2c-feedpoint-sample-impedance feedpoint))))
       #:color color #:style 'short-dash #:width 2
       #:label (format "~a X" name))))))

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

(define (radiation-cut-renderers pattern
                                 #:component [component 'total]
                                 #:floor-db [floor-db -40]
                                 #:normalize? [normalize? #t])
  (unless (nec2c-pattern? pattern)
    (raise-argument-error 'radiation-cut-renderers "nec2c-pattern?" pattern))
  (unless (and (real? floor-db) (< floor-db 0))
    (raise-argument-error 'radiation-cut-renderers "negative-real?" floor-db))
  (define samples (nec2c-pattern-samples pattern))
  (define transform
    (gain-transform (map (lambda (sample) (sample-gain sample component)) samples)
                    floor-db normalize?))
  (define points
    (filter
     values
     (for/list ([sample (in-list samples)])
       (define radius (transform (sample-gain sample component)))
       (and radius
            (let ([angle (degrees->radians (pattern-angle pattern sample))])
              (vector (* radius (cos angle)) (* radius (sin angle))))))))
  (list (polar-axes)
        (lines points #:color "steelblue" #:width 2
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

(define (gui-procedure name)
  (with-handlers ([exn:fail?
                   (lambda (failure)
                     (raise-user-error
                      name "could not start the Plot viewer: ~a"
                      (exn-message failure)))])
    (dynamic-require 'plot name)))

(define (show-plot procedure-name renderers . keyword-arguments)
  (define procedure (gui-procedure procedure-name))
  (define plot-new-window? (dynamic-require 'plot 'plot-new-window?))
  ;; keyword-apply requires its keywords to be sorted. Keeping this detail
  ;; here lets individual viewers state their plotting options naturally.
  (define sorted-arguments
    (sort keyword-arguments keyword<? #:key car))
  (parameterize ([plot-new-window? #t])
    (keyword-apply procedure
                   (for/list ([pair (in-list sorted-arguments)]) (car pair))
                   (for/list ([pair (in-list sorted-arguments)]) (cdr pair))
                   (list renderers))))

(define (show-vswr-sweep result #:max-vswr [max-vswr #f])
  (show-plot
   'plot
   (vswr-sweep-renderers result #:max-vswr max-vswr)
   (cons '#:title "NEC2C VSWR sweep")
   (cons '#:x-label "frequency (MHz)")
   (cons '#:y-label
         (format "VSWR (Z0 = ~a ohms)"
                 (nec2c-sweep-result-reference-impedance result)))))

(define (show-impedance-sweep result)
  (show-plot 'plot
             (impedance-sweep-renderers result)
             (cons '#:title "NEC2C active impedance")
             (cons '#:x-label "frequency (MHz)")
             (cons '#:y-label "ohms")))

(define (show-radiation-cut pattern
                            #:component [component 'total]
                            #:floor-db [floor-db -40]
                            #:normalize? [normalize? #t])
  (show-plot
   'plot
   (radiation-cut-renderers pattern
                            #:component component
                            #:floor-db floor-db
                            #:normalize? normalize?)
   (cons '#:title (format "NEC2C ~a pattern" (nec2c-pattern-kind pattern)))
   (cons '#:x-label #f)
   (cons '#:y-label #f)))

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
