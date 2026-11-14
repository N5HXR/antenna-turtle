#lang racket/base

;; Native far-field polarization workbench. The production radiation entry
;; point dispatches here when #:view 'polarization is requested.

(require pict3d
         racket/class
         racket/format
         racket/gui/base
         racket/list
         racket/math
         "measurement-radiation.rkt"
         "nec2c.rkt"
         "nec2c-opengl-view.rkt"
         "rf-phase-clock.rkt"
         "visualization-handle.rkt")

(provide show-polarization-pattern
         show-polarization-surface-poc
         surface-point->angles
         advance-polarization-phase
         signed-circularity-color
         axial-ratio-color
         polarization-glyph-frame-for
         polarization-glyph-angles
         polarization-glyph-angles-by-gain
         polarization-glyph-hostable?
         (struct-out polarization-glyph-frame)
         make-polarization-color-at
         gain->brightness
         polarization-inspector-text)

(define view-fov-degrees 34)
(define default-azimuth -42.0)
(define default-altitude 24.0)
(define default-zoom 3.1)

;; Gain owns brightness while polarization owns hue. This is an exposure
;; scale rather than darkening alone: high-gain colors are boosted above their
;; authored RGB anchors, while the floor keeps weak lobes visible. The strong
;; exponent opens up contrast within the larger lobes.
(define polarization-brightness-floor 0.1)
(define polarization-brightness-ceiling 1.25)
(define polarization-brightness-exponent 1.2)

;; Frozen M3 palette. Each anchor contains the same three channel levels in a
;; different order, preserving vivid transitions without passing through gray.
(define lhcp-color '(255 32 128))
(define linear-color '(128 255 32))
(define rhcp-color '(32 128 255))
(define undefined-polarization-color '(20 20 26))
(define linear-axial-ratio-color '(48 24 128))
(define circular-axial-ratio-color '(255 240 48))
(define polarization-surface-modes '(signed-circularity axial-ratio))

(struct polarization-glyph-frame
  (direction major-axis minor-axis minor/major)
  #:transparent)

(struct polarization-glyph-instance
  (center frame theta-axis phi-axis e-theta e-phi)
  #:transparent)

(define (interpolate-rgb left right fraction)
  (for/list ([a (in-list left)] [b (in-list right)])
    (+ a (* fraction (- b a)))))

(define (signed-circularity-color circularity)
  (unless (or (not circularity)
              (and (real? circularity) (<= -1 circularity 1)))
    (raise-argument-error
     'signed-circularity-color "(or/c #f (real-in -1 1))" circularity))
  (cond
    [(not circularity) undefined-polarization-color]
    [(negative? circularity)
     (interpolate-rgb lhcp-color linear-color (+ circularity 1.0))]
    [else
     (interpolate-rgb linear-color rhcp-color circularity)]))

(define (axial-ratio-color ratio)
  (unless (or (not ratio)
              (and (real? ratio) (>= ratio 1)))
    (raise-argument-error
     'axial-ratio-color "(or/c #f (real-in 1 +inf.0))" ratio))
  (if (not ratio)
      undefined-polarization-color
      (interpolate-rgb
       linear-axial-ratio-color circular-axial-ratio-color
       (if (infinite? ratio) 0.0 (/ 1.0 ratio)))))

(define (polarization-glyph-frame-for theta-deg phi-deg axial-ratio tilt-deg)
  (unless (and (real? theta-deg) (real? phi-deg))
    (raise-arguments-error
     'polarization-glyph-frame-for "angles must be real"
     "theta" theta-deg "phi" phi-deg))
  (unless (and (real? axial-ratio) (>= axial-ratio 1))
    (raise-argument-error
     'polarization-glyph-frame-for "(real-in 1 +inf.0)" axial-ratio))
  (unless (or (not tilt-deg) (real? tilt-deg))
    (raise-argument-error
     'polarization-glyph-frame-for "(or/c #f real?)" tilt-deg))
  (define theta (degrees->radians theta-deg))
  (define phi (degrees->radians phi-deg))
  (define tilt (degrees->radians (or tilt-deg 0.0)))
  (define direction
    (vector (* (sin theta) (cos phi))
            (* (sin theta) (sin phi))
            (cos theta)))
  (define e-theta
    (vector (* (cos theta) (cos phi))
            (* (cos theta) (sin phi))
            (- (sin theta))))
  (define e-phi (vector (- (sin phi)) (cos phi) 0.0))
  (define (combine-basis theta-weight phi-weight)
    (for/vector ([theta-component (in-vector e-theta)]
                 [phi-component (in-vector e-phi)])
      (+ (* theta-weight theta-component)
         (* phi-weight phi-component))))
  (polarization-glyph-frame
   direction
   (combine-basis (cos tilt) (sin tilt))
   (combine-basis (- (sin tilt)) (cos tilt))
   (if (infinite? axial-ratio) 0.0 (/ 1.0 axial-ratio))))

(define (angle-near? left right)
  (< (abs (- left right)) 1e-7))

(define (stride-angle-values values stride forced-values)
  (remove-duplicates
   (sort
    (append
     (for/list ([value (in-list values)] [index (in-naturals)]
                #:when (zero? (modulo index stride)))
       value)
     (for*/list ([forced (in-list forced-values)]
                 [value (in-list values)]
                 #:when (angle-near? value forced))
       value))
    <)))

(define (polarization-glyph-angles grid stride)
  (unless (nec2c-pattern-grid? grid)
    (raise-argument-error
     'polarization-glyph-angles "nec2c-pattern-grid?" grid))
  (unless (and (exact-integer? stride) (positive? stride))
    (raise-argument-error
     'polarization-glyph-angles "exact-positive-integer?" stride))
  (define thetas
    (stride-angle-values
     (nec2c-pattern-grid-theta-values grid) stride '(0 90 180)))
  (define phis
    (stride-angle-values
     (nec2c-pattern-grid-phi-values grid) stride '(0 90 180 270)))
  (append*
   (for/list ([theta (in-list thetas)])
     (if (or (angle-near? theta 0) (angle-near? theta 180))
         (list (cons theta (first phis)))
         (for/list ([phi (in-list phis)]) (cons theta phi))))))

(define (gain->brightness gain minimum-gain maximum-gain)
  (unless (andmap real? (list gain minimum-gain maximum-gain))
    (raise-arguments-error
     'gain->brightness "gain bounds must be real"
     "gain" gain "minimum gain" minimum-gain "maximum gain" maximum-gain))
  (when (> minimum-gain maximum-gain)
    (raise-arguments-error
     'gain->brightness "minimum gain exceeds maximum gain"
     "minimum gain" minimum-gain "maximum gain" maximum-gain))
  (if (= minimum-gain maximum-gain)
      1.0
      (let* ([normalized
              (max 0.0
                   (min 1.0
                        (/ (- gain minimum-gain)
                           (- maximum-gain minimum-gain))))]
             [curved (expt normalized polarization-brightness-exponent)])
        (+ polarization-brightness-floor
           (* (- polarization-brightness-ceiling
                 polarization-brightness-floor)
              curved)))))

(define (finite-real? value)
  (and (real? value) (< -inf.0 value +inf.0)))

(define (total-gain-range grid)
  (define gains
    (filter finite-real?
            (map nec2c-pattern-sample-total-gain-db
                 (nec2c-pattern-grid-samples grid))))
  (if (null? gains)
      (values 0.0 0.0)
      (values (apply min gains) (apply max gains))))

(define (scale-rgb rgb brightness)
  (map (lambda (channel) (min 255.0 (* channel brightness))) rgb))

(define (polarization-angle-key theta phi)
  (define normalized-phi
    (- phi (* 360.0 (floor (/ phi 360.0)))))
  (cons (inexact->exact (round (* theta 1000000)))
        (inexact->exact (round (* normalized-phi 1000000)))))

(define (make-polarization-color-at grid
                                    #:mode [mode 'signed-circularity])
  (unless (nec2c-pattern-grid? grid)
    (raise-argument-error
     'make-polarization-color-at "nec2c-pattern-grid?" grid))
  (unless (memq mode polarization-surface-modes)
    (raise-argument-error
     'make-polarization-color-at
     "(or/c 'signed-circularity 'axial-ratio)" mode))
  ;; The surface constructor visits only sampled angular vertices. Analyze
  ;; each solver sample once so polarization coloring remains linear in grid
  ;; size instead of repeatedly searching the grid during triangulation.
  (define colors (make-hash))
  (define-values (minimum-gain maximum-gain) (total-gain-range grid))
  (for ([sample (in-list (nec2c-pattern-grid-samples grid))])
    (define state
      (with-handlers ([exn:fail? (lambda (_failure) #f)])
        (analyze-polarization (nec2c-pattern-sample-e-theta sample)
                              (nec2c-pattern-sample-e-phi sample))))
    (define gain
      (let ([sample-gain (nec2c-pattern-sample-total-gain-db sample)])
        (if (finite-real? sample-gain) sample-gain minimum-gain)))
    (define hue
      (cond
        [(eq? mode 'signed-circularity)
         (signed-circularity-color
          (and state (polarization-state-signed-circularity state)))]
        [else
         (axial-ratio-color
          (and state (polarization-state-axial-ratio state)))]))
    (hash-set!
     colors
     (polarization-angle-key
      (nec2c-pattern-sample-theta-deg sample)
      (nec2c-pattern-sample-phi-deg sample))
     (scale-rgb hue
                (gain->brightness gain minimum-gain maximum-gain))))
  (lambda (theta phi)
    (if (and (real? theta) (real? phi))
        (hash-ref colors (polarization-angle-key theta phi)
                  undefined-polarization-color)
        undefined-polarization-color)))

(define normalize-degrees normalize-rf-phase)
(define advance-polarization-phase advance-rf-phase)

;; Radiation surfaces are radial about the RF origin even though the camera is
;; framed around the surface bounds. Convert an exact traced surface point to
;; the public azimuth/elevation convention used by gain-at and polarization-at.
(define (surface-point->angles x y z)
  (unless (andmap real? (list x y z))
    (raise-arguments-error
     'surface-point->angles "coordinates must be real"
     "x" x "y" y "z" z))
  (define radius (sqrt (+ (sqr x) (sqr y) (sqr z))))
  (when (< radius 1e-12)
    (raise-arguments-error
     'surface-point->angles "the RF origin has no angular direction"
     "point" (vector x y z)))
  (values (if (and (zero? x) (zero? y))
              0.0
              (normalize-degrees (radians->degrees (atan y x))))
          (radians->degrees (asin (max -1.0 (min 1.0 (/ z radius)))))))

(define (camera-affine view-center radius azimuth altitude zoom)
  (define az (degrees->radians azimuth))
  (define alt (degrees->radians altitude))
  (define distance (* radius zoom))
  (point-at
   (pos (+ (pos-x view-center) (* distance (cos alt) (cos az)))
        (+ (pos-y view-center) (* distance (cos alt) (sin az)))
        (+ (pos-z view-center) (* distance (sin alt))))
   view-center))

(define (camera-scene surface view-center radius azimuth altitude zoom)
  (combine surface
           (basis 'camera
                  (camera-affine view-center radius azimuth altitude zoom))))

(define (arrl-radius-for-gain gain peak-gain)
  (expt 0.89 (/ (- (max -100 (- gain peak-gain))) 2)))

(define (offset-pos center first-axis first-scale second-axis second-scale)
  (pos (+ (pos-x center)
          (* first-scale (vector-ref first-axis 0))
          (* second-scale (vector-ref second-axis 0)))
       (+ (pos-y center)
          (* first-scale (vector-ref first-axis 1))
          (* second-scale (vector-ref second-axis 1)))
       (+ (pos-z center)
          (* first-scale (vector-ref first-axis 2))
          (* second-scale (vector-ref second-axis 2)))))

(define glyph-material
  (material #:ambient 1.0
            #:diffuse 0.0
            #:specular 0.0
            #:roughness 1.0))

(define (grid-sample-table grid)
  (for/hash ([sample (in-list (nec2c-pattern-grid-samples grid))])
    (values
     (polarization-angle-key
      (nec2c-pattern-sample-theta-deg sample)
      (nec2c-pattern-sample-phi-deg sample))
     sample)))

(define (axis-glyph-angle? angle)
  (define theta (car angle))
  (define phi (cdr angle))
  (or (angle-near? theta 0)
      (angle-near? theta 180)
      (and (angle-near? theta 90)
           (ormap (lambda (cardinal) (angle-near? phi cardinal))
                  '(0 90 180 270)))))

(define (sample-surface-position sample peak-gain)
  (define theta
    (degrees->radians (nec2c-pattern-sample-theta-deg sample)))
  (define phi
    (degrees->radians (nec2c-pattern-sample-phi-deg sample)))
  (define radius
    (arrl-radius-for-gain
     (nec2c-pattern-sample-total-gain-db sample) peak-gain))
  (pos (* radius (sin theta) (cos phi))
       (* radius (sin theta) (sin phi))
       (* radius (cos theta))))

;; Greedy surface-space sampling makes glyph density follow displayed lobe
;; area. Large lobes receive more glyphs while shriveled lobes no longer pack
;; many angular samples into the same small patch.
(define (polarization-glyph-angles-by-gain grid spacing-deg)
  (unless (nec2c-pattern-grid? grid)
    (raise-argument-error
     'polarization-glyph-angles-by-gain "nec2c-pattern-grid?" grid))
  (unless (and (real? spacing-deg) (positive? spacing-deg))
    (raise-argument-error
     'polarization-glyph-angles-by-gain "positive-real?" spacing-deg))
  (define table (grid-sample-table grid))
  (define-values (_minimum-gain peak-gain) (total-gain-range grid))
  (define all-angles (polarization-glyph-angles grid 1))
  (define (sample-for angle)
    (hash-ref table (polarization-angle-key (car angle) (cdr angle)) #f))
  (define usable-angles
    (filter
     (lambda (angle)
       (define sample (sample-for angle))
       (and sample
            (finite-real? (nec2c-pattern-sample-total-gain-db sample))))
     all-angles))
  (define forced (filter axis-glyph-angle? usable-angles))
  (define remaining
    (sort (filter (lambda (angle) (not (member angle forced))) usable-angles)
          >
          #:key (lambda (angle)
                  (nec2c-pattern-sample-total-gain-db (sample-for angle)))))
  (define minimum-distance
    (* 2.0 (sin (/ (degrees->radians (min spacing-deg 179.0)) 2.0))))
  (define selected forced)
  (define selected-positions
    (for/list ([angle (in-list forced)])
      (sample-surface-position (sample-for angle) peak-gain)))
  (for ([angle (in-list remaining)])
    (define point (sample-surface-position (sample-for angle) peak-gain))
    (when (for/and ([selected-point (in-list selected-positions)])
            (>= (pos-dist point selected-point) minimum-distance))
      (set! selected (cons angle selected))
      (set! selected-positions (cons point selected-positions))))
  (sort selected
        (lambda (left right)
          (or (< (car left) (car right))
              (and (= (car left) (car right)) (< (cdr left) (cdr right)))))))

(define (glyph-ring center frame glyph-radius [scale 1.0])
  (define major (polarization-glyph-frame-major-axis frame))
  (define minor (polarization-glyph-frame-minor-axis frame))
  ;; A truly linear state is a zero-width ellipse. Give it a small diagrammatic
  ;; width so it remains a visible blade rather than disappearing edge-on.
  (define minor/major
    (max 0.07 (polarization-glyph-frame-minor/major frame)))
  (for/list ([index (in-range 32)])
    (define angle (* 2 pi (/ index 32.0)))
    (offset-pos center
                major (* glyph-radius scale (cos angle))
                minor (* glyph-radius scale minor/major (sin angle)))))

(define (glyph-vertex point normal color)
  (vertex point
          #:normal (apply dir (vector->list normal))
          #:color (apply rgba color)
          #:material glyph-material))

(define (glyph-annulus outer-ring inner-ring normal color)
  (define outer-vertices
    (for/list ([point (in-list outer-ring)])
      (glyph-vertex point normal color)))
  (define inner-vertices
    (for/list ([point (in-list inner-ring)])
      (glyph-vertex point normal color)))
  (define next-outer
    (append (rest outer-vertices) (list (first outer-vertices))))
  (define next-inner
    (append (rest inner-vertices) (list (first inner-vertices))))
  (combine
   (append*
    (for/list ([outer-a (in-list outer-vertices)]
               [outer-b (in-list next-outer)]
               [inner-a (in-list inner-vertices)]
               [inner-b (in-list next-inner)])
      (list (triangle outer-a inner-b inner-a)
            (triangle outer-a outer-b inner-b))))))

(define (glyph-sides back-ring front-ring normal color)
  (define back-vertices
    (for/list ([point (in-list back-ring)])
      (glyph-vertex point normal color)))
  (define front-vertices
    (for/list ([point (in-list front-ring)])
      (glyph-vertex point normal color)))
  (define next-back (append (rest back-vertices) (list (first back-vertices))))
  (define next-front
    (append (rest front-vertices) (list (first front-vertices))))
  (combine
   (append*
    (for/list ([back-a (in-list back-vertices)]
               [back-b (in-list next-back)]
               [front-a (in-list front-vertices)]
               [front-b (in-list next-front)])
      (list (triangle back-a front-a front-b)
            (triangle back-a front-b back-b))))))

(define (render-polarization-ring instance glyph-radius)
  (define center (polarization-glyph-instance-center instance))
  (define frame (polarization-glyph-instance-frame instance))
  (define direction (polarization-glyph-frame-direction frame))
  (define front-center
    (offset-pos center direction (* glyph-radius 0.08) direction 0))
  (define outer-back (glyph-ring center frame glyph-radius))
  (define outer-front (glyph-ring front-center frame glyph-radius))
  (define inner-front (glyph-ring front-center frame glyph-radius 0.74))
  (combine
   (glyph-sides outer-back outer-front direction '(1.0 1.0 1.0 1.0))
   (glyph-annulus outer-front inner-front direction '(1.0 1.0 1.0 1.0))))

(define (spherical-tangent-axes theta-deg phi-deg)
  (define theta (degrees->radians theta-deg))
  (define phi (degrees->radians phi-deg))
  (values
   (vector (* (cos theta) (cos phi))
           (* (cos theta) (sin phi))
           (- (sin theta)))
   (vector (- (sin phi)) (cos phi) 0.0)))

(define (pos-radius point)
  (sqrt (+ (sqr (pos-x point))
           (sqr (pos-y point))
           (sqr (pos-z point)))))

;; A fixed-size pedagogical glyph has no honest placement when its entire
;; displayed lobe is smaller than the glyph. Clearance is judged relative to
;; local lobe radius: a large lobe can tolerate more absolute lift without the
;; glyph appearing detached, while a collapsed lobe cannot.
(define (polarization-glyph-hostable? base-radius glyph-radius lift)
  (unless (andmap real? (list base-radius glyph-radius lift))
    (raise-arguments-error
     'polarization-glyph-hostable? "radii and lift must be real"
     "base radius" base-radius "glyph radius" glyph-radius "lift" lift))
  (unless (and (positive? base-radius) (positive? glyph-radius)
               (>= lift 0))
    (raise-arguments-error
     'polarization-glyph-hostable?
     "radii must be positive and lift must be nonnegative"
     "base radius" base-radius "glyph radius" glyph-radius "lift" lift))
  (and (>= base-radius (* glyph-radius 1.25))
       (<= lift (max glyph-radius (* base-radius 0.25)))))

(define (surface-radius-in-direction surface point)
  (define radius (pos-radius point))
  (and (> radius 0)
       (let* ([x (/ (pos-x point) radius)]
              [y (/ (pos-y point) radius)]
              [z (/ (pos-z point) radius)]
              [hit (trace surface
                          (pos (* 3.0 x) (* 3.0 y) (* 3.0 z))
                          (dir (- x) (- y) (- z)))])
         (and hit (pos-radius hit)))))

(define (clearance-adjusted-center surface base-radius frame glyph-radius)
  (define direction (polarization-glyph-frame-direction frame))
  (define safety-margin (* glyph-radius 0.14))
  (define lift safety-margin)
  ;; The ellipse lives in a tangent plane, so on a steep lobe shoulder one
  ;; edge may intersect neighboring surface triangles even when its center is
  ;; clear. Probe the actual rendered surface and iteratively lift the complete
  ;; glyph until every sampled perimeter point clears it.
  (for ([_iteration (in-range 4)])
    (define center
      (pos (* (+ base-radius lift) (vector-ref direction 0))
           (* (+ base-radius lift) (vector-ref direction 1))
           (* (+ base-radius lift) (vector-ref direction 2))))
    (define deficit
      (for/fold ([maximum-deficit 0.0])
                ([point (in-list (glyph-ring center frame glyph-radius))]
                 [index (in-naturals)]
                 #:when (even? index))
        (define surface-radius (surface-radius-in-direction surface point))
        (if surface-radius
            (max maximum-deficit
                 (- (+ surface-radius safety-margin) (pos-radius point)))
            maximum-deficit)))
    (set! lift (+ lift (max 0.0 deficit))))
  (and (polarization-glyph-hostable? base-radius glyph-radius lift)
       (pos (* (+ base-radius lift) (vector-ref direction 0))
            (* (+ base-radius lift) (vector-ref direction 1))
            (* (+ base-radius lift) (vector-ref direction 2)))))

(define (make-polarization-glyph-layout grid surface view-radius spacing-deg)
  (define sample-table (grid-sample-table grid))
  (define-values (_minimum-gain maximum-gain) (total-gain-range grid))
  (define glyph-radius (* view-radius 0.05))
  (filter
   values
   (for/list ([angle (in-list
                      (polarization-glyph-angles-by-gain grid spacing-deg))])
       (define theta (car angle))
       (define phi (cdr angle))
       (define sample
         (hash-ref sample-table (polarization-angle-key theta phi) #f))
       (and sample
            (let* ([gain (nec2c-pattern-sample-total-gain-db sample)]
                   [state
                    (with-handlers ([exn:fail? (lambda (_failure) #f)])
                      (analyze-polarization
                       (nec2c-pattern-sample-e-theta sample)
                       (nec2c-pattern-sample-e-phi sample)))])
              (and (finite-real? gain)
                   state
                   (polarization-state-axial-ratio state)
                   (let* ([frame
                           (polarization-glyph-frame-for
                            theta phi
                            (polarization-state-axial-ratio state)
                            (polarization-state-tilt-deg state))]
                          [radius (arrl-radius-for-gain gain maximum-gain)]
                          [center
                           (clearance-adjusted-center
                            surface radius frame glyph-radius)])
                     (and center
                          (let-values ([(theta-axis phi-axis)
                                        (spherical-tangent-axes theta phi)])
                            (polarization-glyph-instance
                             center frame theta-axis phi-axis
                             (nec2c-pattern-sample-e-theta sample)
                             (nec2c-pattern-sample-e-phi sample)))))))))))

(define (make-polarization-glyph-rings layout view-radius)
  (define glyph-radius (* view-radius 0.05))
  (freeze
   (combine
    (for/list ([instance (in-list layout)])
      (render-polarization-ring instance glyph-radius)))))

(define (complex-instantaneous component phase-radians)
  (- (* (real-part component) (cos phase-radians))
     (* (imag-part component) (sin phase-radians))))

(define (jones-major-amplitude e-theta e-phi)
  (define theta-power (sqr (magnitude e-theta)))
  (define phi-power (sqr (magnitude e-phi)))
  (define cross
    (real-part (* e-theta (conjugate e-phi))))
  (sqrt
   (/ (+ theta-power phi-power
         (sqrt (+ (sqr (- theta-power phi-power))
                  (* 4 (sqr cross)))))
      2.0)))

(define (make-polarization-glyph-beads layout view-radius phase-deg)
  (define glyph-radius (* view-radius 0.05))
  (define bead-radius (* glyph-radius 0.16))
  (define phase-radians (degrees->radians phase-deg))
  (combine
   (filter
    values
    (for/list ([instance (in-list layout)])
      (define e-theta (polarization-glyph-instance-e-theta instance))
      (define e-phi (polarization-glyph-instance-e-phi instance))
      (define major-amplitude (jones-major-amplitude e-theta e-phi))
      (and (> major-amplitude 0)
           (let* ([theta-value
                   (/ (complex-instantaneous e-theta phase-radians)
                      major-amplitude)]
                  [phi-value
                   (/ (complex-instantaneous e-phi phase-radians)
                      major-amplitude)]
                  [orbit-center
                   (offset-pos
                    (polarization-glyph-instance-center instance)
                    (polarization-glyph-frame-direction
                     (polarization-glyph-instance-frame instance))
                    (* glyph-radius 0.10)
                    (polarization-glyph-instance-theta-axis instance)
                    0)]
                  [point
                   (offset-pos
                    orbit-center
                    (polarization-glyph-instance-theta-axis instance)
                    (* glyph-radius theta-value)
                    (polarization-glyph-instance-phi-axis instance)
                    (* glyph-radius phi-value))])
             (with-color (rgba 1.0 1.0 1.0 1.0)
               (with-emitted (emitted 1.0 1.0 1.0 1.0)
                 (sphere point bead-radius)))))))))

(define (backend-title grid)
  (define run (nec2c-pattern-grid-run grid))
  (if (and (hash? run) (eq? (hash-ref run 'backend #f) 'openems))
      "OpenEMS"
      "NEC2C"))

(define (format-number value digits [suffix ""])
  (if (real? value)
      (format "~a~a" (~r (exact->inexact value) #:precision digits) suffix)
      "unavailable"))

(define (format-ratio ratio)
  (cond [(not ratio) "undefined"]
        [(infinite? ratio) "linear (infinite)"]
        [else (format-number ratio 2 ":1")]))

(define (format-tilt tilt)
  (if tilt (format-number tilt 1 " degrees") "undefined"))

(define (polarization-inspector-text grid azimuth elevation maximum-gain)
  (unless (nec2c-pattern-grid? grid)
    (raise-argument-error
     'polarization-inspector-text "nec2c-pattern-grid?" grid))
  (unless (andmap real? (list azimuth elevation maximum-gain))
    (raise-arguments-error
     'polarization-inspector-text "angles and maximum gain must be real"
     "azimuth" azimuth "elevation" elevation
     "maximum gain" maximum-gain))
  (define gain
    (gain-at grid #:azimuth azimuth #:elevation elevation))
  (define state
    (with-handlers ([exn:fail? (lambda (_failure) #f)])
      (polarization-at grid #:azimuth azimuth #:elevation elevation)))
  (string-append
   (format "azimuth      ~a\nelevation    ~a\ntotal gain  ~a\nrelative    ~a"
           (format-number azimuth 2 " degrees")
           (format-number elevation 2 " degrees")
           (format-number gain 2 " dBi")
           (format-number (- gain maximum-gain) 2 " dB"))
   (if state
       (format "\npolarization ~a\naxial ratio  ~a\ntilt angle   ~a"
               (string-upcase
                (symbol->string (polarization-state-sense state)))
               (format-ratio (polarization-state-axial-ratio state))
               (format-tilt (polarization-state-tilt-deg state)))
       "\npolarization unavailable")))

(define polarization-legend-canvas%
  (class canvas%
    (init-field [mode 'signed-circularity])
    (super-new [min-width 276] [min-height 86]
               [stretchable-width #t] [stretchable-height #f])
    (define/public (set-mode new-mode)
      (set! mode new-mode)
      (send this refresh))
    (define/override (on-paint)
      (define dc (send this get-dc))
      (define-values (width height) (send this get-client-size))
      (define left 8)
      (define right (max (+ left 1) (- width 8)))
      (define top 24)
      (define bar-height 18)
      (send dc set-pen "transparent" 0 'transparent)
      (for ([x (in-range left right)])
        (define fraction (/ (- x left) (max 1 (- right left 1))))
        (define rgb
          (if (eq? mode 'signed-circularity)
              (signed-circularity-color (- (* 2.0 fraction) 1.0))
              (axial-ratio-color
               (if (zero? fraction) +inf.0 (/ 1.0 fraction)))))
        (send dc set-brush
              (make-object color%
                           (exact-round (first rgb))
                           (exact-round (second rgb))
                           (exact-round (third rgb)))
              'solid)
        (send dc draw-rectangle x top 1 bar-height))
      (send dc set-text-foreground "black")
      (define left-label
        (if (eq? mode 'signed-circularity) "LHCP" "LINEAR"))
      (define center-label
        (if (eq? mode 'signed-circularity) "LINEAR" "ELLIPTICAL"))
      (define right-label
        (if (eq? mode 'signed-circularity) "RHCP" "CIRCULAR"))
      (send dc draw-text left-label left 2)
      (define-values (center-width _h _d _s)
        (send dc get-text-extent center-label))
      (send dc draw-text center-label (- (/ width 2) (/ center-width 2)) 2)
      (define-values (right-width _rh _rd _rs)
        (send dc get-text-extent right-label))
      (send dc draw-text right-label (- right right-width) 2)
      (define left-value
        (if (eq? mode 'signed-circularity) "-1" "infinite:1"))
      (define center-value (if (eq? mode 'signed-circularity) "0" "2:1"))
      (define right-value (if (eq? mode 'signed-circularity) "+1" "1:1"))
      (send dc draw-text left-value left (+ top bar-height 4))
      (define-values (center-value-width _cvh _cvd _cvs)
        (send dc get-text-extent center-value))
      (send dc draw-text center-value
            (- (/ width 2) (/ center-value-width 2))
            (+ top bar-height 4))
      (define-values (right-value-width _rvh _rvd _rvs)
        (send dc get-text-extent right-value))
      (send dc draw-text right-value (- right right-value-width)
            (+ top bar-height 4)))))

(define polarization-poc-canvas%
  (class pict3d-canvas%
    (init-field surface decoration animation view-center radius selection-callback
                selection-cleared-callback status-label)
    (define azimuth default-azimuth)
    (define altitude default-altitude)
    (define zoom default-zoom)
    (define dragging? #f)
    (define moved? #f)
    (define previous-x 0)
    (define previous-y 0)
    (define down-x 0)
    (define down-y 0)
    (define selection-marker empty-pict3d)
    ;; Camera motion must never rebuild the triangle scene. Pict3D surface
    ;; freezing is substantially more expensive than replacing the camera
    ;; basis, and doing it for every queued mouse-motion event makes an orbit
    ;; continue long after the button is released.
    (define display-base (freeze (combine surface decoration)))
    (define (display-scene)
      (combine display-base animation selection-marker))
    (super-new
     [pict3d (camera-scene (display-scene) view-center
                           radius azimuth altitude zoom)])

    (define/private (update-view!)
      (send status-label set-label
            (format
             "drag to orbit  |  wheel to zoom  |  click surface to inspect  |  click background to clear  |  azimuth ~a degrees  elevation ~a degrees"
             (exact-round azimuth) (exact-round altitude)))
      (parameterize ([current-pict3d-background (rgba "black")]
                     [current-pict3d-ambient (emitted "white" 1.0)]
                     [current-pict3d-fov view-fov-degrees])
        (send this set-pict3d
              (camera-scene (display-scene) view-center radius
                            azimuth altitude zoom))))

    (define/private (clear-selection!)
      (set! selection-marker empty-pict3d)
      (selection-cleared-callback)
      (update-view!))

    (define/private (select-at! x y)
      (define-values (width height) (send this get-client-size))
      (when (and (> width 0) (> height 0))
        (define camera
          (camera-affine view-center radius azimuth altitude zoom))
        (define ray-direction
          ((camera-ray-dir camera
                           #:width width #:height height
                           #:fov view-fov-degrees)
           x y))
        ;; Trace only the data surface, never the selection marker.
        (define hit (trace surface (affine-origin camera) ray-direction))
        (if hit
            (with-handlers ([exn:fail:contract? (lambda (_failure) (void))])
              (define-values (selected-azimuth selected-elevation)
                (surface-point->angles (pos-x hit) (pos-y hit) (pos-z hit)))
              (set! selection-marker
                    (freeze
                     (with-color (rgba 1.0 1.0 1.0 1.0)
                       (with-emitted (emitted 1.0 1.0 1.0 1.0)
                         (sphere hit (* radius 0.022))))))
              (selection-callback selected-azimuth selected-elevation)
              (update-view!))
            (clear-selection!))))

    (define/public (replace-scene! new-surface new-decoration
                                   new-center new-radius)
      (set! surface new-surface)
      (set! decoration new-decoration)
      (set! view-center new-center)
      (set! radius new-radius)
      (set! selection-marker empty-pict3d)
      (selection-cleared-callback)
      (set! display-base (freeze (combine surface decoration)))
      (update-view!))

    ;; Surface metric changes recolor the same geometry, so an exact selected
    ;; direction remains meaningful and its marker should not disappear.
    (define/public (replace-surface-style! new-surface new-center new-radius)
      (set! surface new-surface)
      (set! view-center new-center)
      (set! radius new-radius)
      (set! display-base (freeze (combine surface decoration)))
      (update-view!))

    ;; Glyph visibility and density are overlays on the same data surface.
    ;; Preserve both the selected marker and its inspector while A/B testing.
    (define/public (replace-overlay! new-decoration new-animation)
      (set! decoration new-decoration)
      (set! animation new-animation)
      (set! display-base (freeze (combine surface decoration)))
      (update-view!))

    (define/public (replace-animation! new-animation)
      (set! animation new-animation)
      (update-view!))

    (define/override (on-event event)
      (define type (send event get-event-type))
      (define x (send event get-x))
      (define y (send event get-y))
      (case type
        [(left-down)
         (set! dragging? #t)
         (set! moved? #f)
         (set! down-x x)
         (set! down-y y)
         (set! previous-x x)
         (set! previous-y y)]
        [(left-up)
         (when (and dragging? (not moved?)) (select-at! x y))
         (set! dragging? #f)]
        [(motion)
         (when dragging?
           (when (or (> (abs (- x down-x)) 3) (> (abs (- y down-y)) 3))
             (set! moved? #t))
           (when moved?
             (set! azimuth (- azimuth (* 0.45 (- x previous-x))))
             (set! altitude
                   (max -89.0
                        (min 89.0
                             (+ altitude (* 0.45 (- y previous-y))))))
             (set! previous-x x)
             (set! previous-y y)
             (update-view!)))]
        [(wheel-up)
         (set! zoom (max 1.25 (* zoom 0.88)))
         (update-view!)]
        [(wheel-down)
         (set! zoom (min 20.0 (/ zoom 0.88)))
         (update-view!)]
        [else (void)]))

    (define/override (on-char event)
      (case (send event get-key-code)
        [(wheel-up #\+)
         (set! zoom (max 1.25 (* zoom 0.88)))
         (update-view!)]
        [(wheel-down #\-)
         (set! zoom (min 20.0 (/ zoom 0.88)))
         (update-view!)]
        [else (void)]))))

(define (show-polarization-pattern grid
                                   #:width [width 1180]
                                   #:height [height 780]
                                   #:mesh-step [mesh-step 2])
  (unless (nec2c-pattern-grid? grid)
    (raise-argument-error
     'show-polarization-pattern "nec2c-pattern-grid?" grid))
  (unless (and (exact-integer? width) (positive? width))
    (raise-argument-error
     'show-polarization-pattern "exact-positive-integer?" width))
  (unless (and (exact-integer? height) (positive? height))
    (raise-argument-error
     'show-polarization-pattern "exact-positive-integer?" height))
  (unless (and (real? mesh-step) (positive? mesh-step))
    (raise-argument-error 'show-polarization-pattern
                          "positive-real?" mesh-step))

  (define current-grid grid)
  (define current-surface-mode 'signed-circularity)
  (define phase-clock (make-rf-phase-clock))
  (define initial-color-at
    (make-polarization-color-at grid #:mode current-surface-mode))
  (define-values (minimum-gain maximum-gain) (total-gain-range grid))
  (define-values (surface radius view-center _peak-gain)
    (build-radiation-pict3d
     grid #:scale 'arrl #:mesh-step mesh-step #:color-at initial-color-at))
  (define angular-resolution (pattern-angular-resolution grid))
  (define azimuth-step (or (first angular-resolution) 1.0))
  (define elevation-step (or (second angular-resolution) 1.0))
  (define glyph-base-step (max azimuth-step elevation-step))
  (define maximum-glyph-stride
    (max 1 (inexact->exact (floor (/ 60.0 glyph-base-step)))))
  (define current-glyph-stride
    (max 1
         (min maximum-glyph-stride
              (inexact->exact (round (/ 10.0 glyph-base-step))))))
  (define glyphs-visible? #f)
  (define (current-glyph-spacing)
    (* current-glyph-stride glyph-base-step))
  (define glyph-layout '())
  (define decoration empty-pict3d)
  (define animation empty-pict3d)
  ;; Leave room for the window manager and desktop chrome on shorter screens.
  ;; The scrollable control rail below prevents its children from increasing
  ;; the frame's minimum height beyond this display-aware bound.
  (define-values (_display-width display-height) (get-display-size))
  (define window-height
    (min height (max 240 (- display-height 80))))
  (define frame
    (new frame%
         [label (format "~a polarization workbench"
                        (backend-title grid))]
         [width width]
         [height window-height]))
  (define eventspace (current-eventspace))
  (define root (new vertical-panel% [parent frame]))
  (define body (new horizontal-panel% [parent root]))
  (define viewport (new vertical-panel% [parent body]))
  (define rail
    (new vertical-panel%
         [parent body]
         [min-width 300]
         [style '(auto-vscroll)]
         [stretchable-width #f]
         [alignment '(left top)]
         [vert-margin 12]
         [horiz-margin 12]
         [spacing 10]))
  (define footer
    (new horizontal-panel%
         [parent root]
         [stretchable-height #f]
         [alignment '(left center)]))
  (define status
    (new message%
         [parent footer]
         [label "drag to orbit  |  wheel to zoom  |  click surface to inspect  |  click background to clear"]
         [stretchable-width #t]))

  (define (surface-mode-title)
    (if (eq? current-surface-mode 'signed-circularity)
        "SIGNED CIRCULARITY"
        "AXIAL RATIO"))

  (define (surface-summary-text minimum maximum)
    (format
     "~a SURFACE\nARRL radius from total gain\nbrightness ~a to ~a"
     (surface-mode-title)
     (format-number minimum 2 " dBi")
     (format-number maximum 2 " dBi")))

  (new message% [parent rail] [label "POLARIZATION WORKBENCH"])
  (define surface-summary
    (new message%
         [parent rail]
         [label (surface-summary-text minimum-gain maximum-gain)]
         [auto-resize #t]
         [stretchable-width #t]))
  (define canvas #f)
  (define surface-rebuild-timer #f)
  (define glyph-rebuild-timer #f)
  (define timer #f)
  (define (sync-animation-timer!)
    (when timer
      (if (and glyphs-visible?
               (rf-phase-clock-running? phase-clock)
               (send frame is-shown?))
          (begin
            (rf-phase-clock-start! phase-clock)
            (send timer start 33))
          (send timer stop))))
  (define (schedule-surface-rebuild!)
    (when surface-rebuild-timer
      (send surface-rebuild-timer stop)
      (send surface-rebuild-timer start 120 #t)))
  (define (schedule-glyph-rebuild!)
    (when glyph-rebuild-timer
      (send glyph-rebuild-timer stop)
      (send glyph-rebuild-timer start 160 #t)))
  (new message% [parent rail] [label "SURFACE"])
  (new choice%
       [parent rail]
       [label #f]
       [choices '("SIGNED CIRCULARITY" "AXIAL RATIO")]
       [selection 0]
       [callback
        (lambda (choice _event)
          (set! current-surface-mode
                (if (zero? (send choice get-selection))
                    'signed-circularity
                    'axial-ratio))
          (schedule-surface-rebuild!))])
  (define legend
    (new polarization-legend-canvas%
         [parent rail]
         [mode current-surface-mode]))
  (define glyph-spacing-slider #f)
  (define phase-slider #f)
  (define play-button #f)
  (define speed-slider #f)
  (define (enable-glyph-controls! enabled?)
    (for ([control (in-list
                    (filter values
                            (list glyph-spacing-slider phase-slider
                                  play-button speed-slider)))])
      (send control enable enabled?)))
  (new check-box%
       [parent rail]
       [label "SHOW POLARIZATION GLYPHS"]
       [value #f]
       [callback
        (lambda (control _event)
          (set! glyphs-visible? (send control get-value))
          (enable-glyph-controls! glyphs-visible?)
          (schedule-glyph-rebuild!)
          (sync-animation-timer!))])
  (define glyph-spacing-label
    (new message%
         [parent rail]
         [label
          (format "GLYPH SPACING  ~a degrees at peak gain"
                  (current-glyph-spacing))]
         [auto-resize #t]
         [stretchable-width #t]))
  (set! glyph-spacing-slider
        (new slider%
             [parent rail]
             [label #f]
             [min-value 1]
             [max-value maximum-glyph-stride]
             [init-value current-glyph-stride]
             [callback
              (lambda (control _event)
                (set! current-glyph-stride (send control get-value))
                (send glyph-spacing-label set-label
                      (format "GLYPH SPACING  ~a degrees at peak gain"
                              (current-glyph-spacing)))
                (schedule-glyph-rebuild!))]))
  (new message%
       [parent rail]
       [label (string-append
               "Sense is viewed from behind the antenna,\n"
               "looking outward along propagation.\n"
               "Clockwise field rotation is RHCP.")]
       [stretchable-width #t])
  (new message% [parent rail] [label "SELECTED DIRECTION"])
  (define selection-summary
    (new message%
         [parent rail]
         [label "Click the pattern surface\nto inspect an exact direction."]
         [auto-resize #t]
         [stretchable-width #t]))

  (define (clear-selection!)
    (send selection-summary set-label
          "Click the pattern surface\nto inspect an exact direction."))

  (new message% [parent rail] [label "RF PHASE"])
  (define phase-label
    (new message% [parent rail] [label "0 degrees"]
         [auto-resize #t] [stretchable-width #t]))
  (set! phase-slider
        (new slider%
             [parent rail]
             [label #f]
             [min-value 0]
             [max-value 359]
             [init-value 0]
             [callback
              (lambda (control _event)
                (rf-phase-clock-set-phase!
                 phase-clock (send control get-value))
                (send phase-label set-label
                      (format "~a degrees"
                              (exact-round
                               (rf-phase-clock-phase phase-clock))))
                (when canvas
                  (set! animation
                        (if glyphs-visible?
                            (make-polarization-glyph-beads
                             glyph-layout radius
                             (rf-phase-clock-phase phase-clock))
                            empty-pict3d))
                  (send canvas replace-animation! animation)))]))
  (define playback-row
    (new horizontal-panel%
         [parent rail]
         [stretchable-height #f]
         [alignment '(left center)]))
  (set! play-button
        (new button%
             [parent playback-row]
             [label "PAUSE"]
             [callback
              (lambda (button _event)
                (if (rf-phase-clock-running? phase-clock)
                    (rf-phase-clock-stop! phase-clock)
                    (rf-phase-clock-start! phase-clock))
                (send button set-label
                      (if (rf-phase-clock-running? phase-clock)
                          "PAUSE" "PLAY"))
                (sync-animation-timer!))]))
  (define speed-label
    (new message% [parent playback-row] [label "speed 1.00x"]))
  (set! speed-slider
        (new slider%
             [parent rail]
             [label #f]
             [min-value 10]
             [max-value 400]
             [init-value 100]
             [callback
              (lambda (control _event)
                (rf-phase-clock-set-speed!
                 phase-clock (/ (send control get-value) 100.0))
                (send speed-label set-label
                      (format "speed ~ax"
                              (~r (rf-phase-clock-speed phase-clock)
                                  #:precision 2))))]))
  (new message%
       [parent rail]
       [label "POLARIZATION GLYPHS\nRing shape shows axial ratio.\nRing angle shows polarization tilt.\nBead motion shows instantaneous E-field phase."]
       [stretchable-width #t])
  (enable-glyph-controls! #f)

  (define (select-direction! azimuth elevation)
    (send selection-summary set-label
          (polarization-inspector-text
           current-grid azimuth elevation maximum-gain)))

  (parameterize ([current-pict3d-background (rgba "black")]
                 [current-pict3d-ambient (emitted "white" 1.0)]
                 [current-pict3d-fov view-fov-degrees])
    (set! canvas
          (new polarization-poc-canvas%
               [parent viewport]
               [surface surface]
               [decoration decoration]
               [animation animation]
               [view-center view-center]
               [radius radius]
               [selection-callback select-direction!]
               [selection-cleared-callback clear-selection!]
               [status-label status])))
  (send canvas set-async-updates? #t)

  (define (rebuild-surface!)
    (define color-at
      (make-polarization-color-at current-grid #:mode current-surface-mode))
    (define-values (new-surface new-radius new-center _new-peak)
      (build-radiation-pict3d
       current-grid #:scale 'arrl #:mesh-step mesh-step #:color-at color-at))
    (set! surface new-surface)
    (set! radius new-radius)
    (set! view-center new-center)
    (send legend set-mode current-surface-mode)
    (send surface-summary set-label
          (surface-summary-text minimum-gain maximum-gain))
    (send canvas replace-surface-style! surface view-center radius))

  (define (rebuild-glyphs!)
    (set! glyph-layout
          (if glyphs-visible?
              (make-polarization-glyph-layout
               current-grid surface radius (current-glyph-spacing))
              '()))
    (set! decoration
          (if glyphs-visible?
              (make-polarization-glyph-rings glyph-layout radius)
              empty-pict3d))
    (set! animation
          (if glyphs-visible?
              (make-polarization-glyph-beads
               glyph-layout radius (rf-phase-clock-phase phase-clock))
              empty-pict3d))
    (send canvas replace-overlay! decoration animation))

  (set! surface-rebuild-timer
        (new timer%
             [notify-callback rebuild-surface!]))
  (set! glyph-rebuild-timer
        (new timer%
             [notify-callback rebuild-glyphs!]))

  (set! timer
        (new timer%
         [notify-callback
          (lambda ()
            (cond
              [(or (not (send frame is-shown?))
                   (not glyphs-visible?)
                   (not (rf-phase-clock-running? phase-clock)))
               (send timer stop)]
              [else
               (define phase (rf-phase-clock-tick! phase-clock))
               (define displayed (modulo (exact-round phase) 360))
               (send phase-slider set-value displayed)
               (send phase-label set-label
                     (format "~a degrees" displayed))
               (set! animation
                     (make-polarization-glyph-beads
                      glyph-layout radius phase))
               (send canvas replace-animation! animation)]))]))

  (send frame show #t)
  (sync-animation-timer!)
  (make-visualization-handle
   (lambda (new-grid)
     (unless (nec2c-pattern-grid? new-grid)
       (raise-argument-error
        'visualization-update! "nec2c-pattern-grid?" new-grid))
     (define new-color-at
       (make-polarization-color-at new-grid #:mode current-surface-mode))
     (define-values (new-minimum-gain new-maximum-gain)
       (total-gain-range new-grid))
     (define-values (new-surface new-radius new-center _new-peak)
       (build-radiation-pict3d
        new-grid #:scale 'arrl #:mesh-step mesh-step
        #:color-at new-color-at))
     (define new-layout
       (if glyphs-visible?
           (make-polarization-glyph-layout
            new-grid new-surface new-radius (current-glyph-spacing))
           '()))
     (define new-decoration
       (if glyphs-visible?
           (make-polarization-glyph-rings new-layout new-radius)
           empty-pict3d))
     (define new-animation
       (if glyphs-visible?
           (make-polarization-glyph-beads
            new-layout new-radius (rf-phase-clock-phase phase-clock))
           empty-pict3d))
     (set! current-grid new-grid)
     (set! surface new-surface)
     (set! glyph-layout new-layout)
     (set! decoration new-decoration)
     (set! animation new-animation)
     (set! radius new-radius)
     (set! view-center new-center)
     (set! minimum-gain new-minimum-gain)
     (set! maximum-gain new-maximum-gain)
     (parameterize ([current-eventspace eventspace])
       (queue-callback
        (lambda ()
          (send surface-summary set-label
                (surface-summary-text new-minimum-gain new-maximum-gain))
          (send canvas replace-scene!
                new-surface new-decoration new-center new-radius)
          (send canvas replace-animation! new-animation))
        #f)))
   (lambda ()
     (parameterize ([current-eventspace eventspace])
       (queue-callback (lambda ()
                         (send frame show #t)
                         (sync-animation-timer!))
                       #f)))
   (lambda ()
     (parameterize ([current-eventspace eventspace])
       (queue-callback (lambda ()
                         (send timer stop)
                         (send frame show #f))
                       #f)))
   (lambda () (send frame is-shown?))))

;; Retained while feature-branch sketches migrate to the production entry
;; point in nec2c-view.rkt.
(define show-polarization-surface-poc show-polarization-pattern)
