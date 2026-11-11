#lang racket/base

(require pict3d
         racket/class
         racket/gui/base
         racket/list
         racket/math
         racket/port
         racket/string
         racket/system
         typed/opengl
         typed/opengl/ffi
         (only-in typed/opengl/utils load-shader create-program)
         (only-in "core.rkt"
                  model-edges
                  point3 point3-x point3-y point3-z
                  vertex-point
                  wire-edge-start wire-edge-end wire-edge-feed?
                  wire-edge-feed-location)
         "radiation-case.rkt"
         "visualization-handle.rkt"
         "near-field-particle.rkt"
         "nec2c.rkt")

(provide show-radiation-pattern-opengl
         show-near-field-poynting-particles
         show-radiation-palette-lab
         show-radiation-comparison
         radiation-grid->pict3d)

;; MMANA retains its conventional nonlinear stop distribution. The other
;; ramps share a gentler perceptual curve: fine resolution through the first
;; few dB of the main lobe, useful midtones around ordinary lobe ratios, and a
;; quicker transition through the uncommon deep-null range.
(define mmana-color-stops
  '((-30 . (12 20 180))
    (-20 . (0 100 255))
    (-10 . (0 230 255))
    (-6  . (0 238 95))
    (-3  . (235 255 18))
    (-1.5 . (255 192 18))
    (-0.5 . (255 58 18))
    (0 . (255 20 205))))

(define shaped-ramp-levels '(-30 -25 -19 -15 -11 -7 -3 -1 0))

(define (shape-ramp colors)
  (unless (= (length colors) (length shaped-ramp-levels))
    (error 'shape-ramp "expected ~a colors, received ~a"
           (length shaped-ramp-levels) (length colors)))
  (map cons shaped-ramp-levels colors))

(define magma-color-stops
  (shape-ramp
   '((0 0 4) (28 16 68) (79 18 123) (129 37 129) (181 54 122)
     (229 80 100) (251 135 97) (254 194 135) (252 253 191))))

(define inferno-color-stops
  (shape-ramp
   '((0 0 4) (31 12 72) (85 15 109) (136 34 106) (186 54 85)
     (227 89 51) (249 140 10) (249 201 50) (252 255 164))))

(define viridis-color-stops
  (shape-ramp
   '((68 1 84) (72 40 120) (62 74 137) (49 104 142) (38 130 142)
     (31 158 137) (53 183 121) (109 205 89) (253 231 37))))

(define grayscale-color-stops
  (shape-ramp
   '((24 24 24) (50 50 50) (75 75 75) (123 123 123) (133 133 133)
     (164 164 164) (194 194 194) (225 225 225) (255 255 255))))

(define hot-eletric-stops
  (shape-ramp
   '((0 0 4) (0 0 48) (0 0 105) (35 0 145) (85 0 175)
     (145 0 205) (215 0 235) (255 45 245) (255 190 255))))

(define (resolve-palette who palette)
  (case palette
    [(mmana) mmana-color-stops]
    [(magma sdr) magma-color-stops]
    [(inferno) inferno-color-stops]
    [(viridis) viridis-color-stops]
    [(grayscale) grayscale-color-stops]
    [(electric) hot-eletric-stops]
    [else
     (raise-argument-error
      who
      "(or/c 'mmana 'magma 'sdr 'inferno 'viridis 'grayscale 'electric)"
      palette)]))

(define surface-material
  (material #:ambient 0.94
            #:diffuse 0.06
            #:specular 0.0
            #:roughness 1.0))

(define (sample-gain sample component)
  (case component
    [(total) (nec2c-pattern-sample-total-gain-db sample)]
    [(vertical) (nec2c-pattern-sample-vertical-gain-db sample)]
    [(horizontal) (nec2c-pattern-sample-horizontal-gain-db sample)]
    [else
     (raise-argument-error
      'radiation-pattern "(or/c 'total 'vertical 'horizontal)" component)]))

(define (sample-direction sample)
  (or (nec2c-pattern-sample-direction sample)
      (let* ([theta (degrees->radians
                     (nec2c-pattern-sample-theta-deg sample))]
             [phi (degrees->radians
                   (nec2c-pattern-sample-phi-deg sample))])
        (vector (* (sin theta) (cos phi))
                (* (sin theta) (sin phi))
                (cos theta)))))

(define (radiation-backend-title grid)
  (define run (nec2c-pattern-grid-run grid))
  (if (and (hash? run) (eq? (hash-ref run 'backend #f) 'openems))
      "OpenEMS"
      "NEC2C"))

(define (interpolate-color a b fraction)
  (for/list ([component-a (in-list a)]
             [component-b (in-list b)])
    (+ component-a (* fraction (- component-b component-a)))))

;; Pattern differences use a deliberately separate diverging ramp.  The
;; ordinary palettes encode magnitude from a peak; this ramp encodes a signed
;; change in absolute dBi and must make zero visually unambiguous.
(define difference-negative-color '(40 110 255))
(define difference-zero-color '(224 224 224))
(define difference-positive-color '(255 70 55))

(define (difference-color difference-db range-db)
  (cond
    [(zero? range-db) difference-zero-color]
    [else
     (define bounded (max (- range-db) (min range-db difference-db)))
     (if (negative? bounded)
         (interpolate-color difference-negative-color difference-zero-color
                            (/ (+ bounded range-db) range-db))
         (interpolate-color difference-zero-color difference-positive-color
                            (/ bounded range-db)))]))

(define (relative-gain-color gain-db color-stops)
  (define bounded (min 0 (max -30 gain-db)))
  (let loop ([lower (first color-stops)]
             [remaining (rest color-stops)])
    (cond
      [(null? remaining) (cdr lower)]
      [else
       (define upper (first remaining))
       (define lower-db (car lower))
       (define upper-db (car upper))
       (if (<= bounded upper-db)
           (interpolate-color
            (cdr lower) (cdr upper)
            (/ (- bounded lower-db) (- upper-db lower-db)))
           (loop upper (rest remaining)))])))

(define (validate-color-step who color-step)
  (unless (or (not color-step)
              (and (real? color-step) (positive? color-step)))
    (raise-argument-error who "(or/c #f positive-real?)" color-step)))

(define (color-gain gain-db color-step)
  (define bounded (min 0 (max -30 gain-db)))
  (if color-step
      ;; Each interval takes the color at its upper boundary: for a 3 dB
      ;; step, [-3,0) uses the 0 dB color and [-6,-3) uses the -3 dB color.
      (- (* color-step (floor (/ (- bounded) color-step))))
      bounded))

(define (ground-horizon? theta-values)
  (and (pair? theta-values)
       (< (abs (- (last theta-values) 90)) 1e-6)))

(define (angle-key theta phi)
  (cons (inexact->exact (round (* theta 1000000)))
        (inexact->exact (round (* phi 1000000)))))

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

(define (coordinate-triad radius)
  ;; This is retained for callers that explicitly request axes from the
  ;; low-level Pict3D constructor. The interactive viewer uses the reliable
  ;; screen-space orientation widget below instead.
  (freeze
   (combine
    (with-color (rgba "red")
      (arrow origin (dir radius 0 0)))
    (with-color (rgba "blue")
      (arrow origin (dir 0 radius 0)))
    (with-color (rgba "green")
      (arrow origin (dir 0 0 radius))))))

(define (validate-radial-scale who scale)
  (unless (memq scale '(arrl db))
    (raise-argument-error who "(or/c 'arrl 'db)" scale)))

(define (scaled-radius gain peak floor-db normalize? radial-scale)
  (define display-db (if normalize? (- gain peak) gain))
  (case radial-scale
    [(arrl)
     ;; The traditional modified-log ARRL scale uses 0.89 of the
     ;; preceding radius for each 2 dB of attenuation. Treat -100 dB as
     ;; the practical chart center, as the published grid does.
     (expt 0.89 (/ (- (max -100 display-db)) 2))]
    [(db)
     (- (max floor-db display-db) floor-db)]))

(define (build-radiation-pict3d grid
                                #:component [component 'total]
                                #:floor-db [floor-db -40]
                                #:normalize? [normalize? #t]
                                #:scale [radial-scale 'arrl]
                                #:palette [palette 'mmana]
                                #:color-stops [supplied-color-stops #f]
                                #:color-step [color-step #f]
                                #:mesh-step [mesh-step 2]
                                #:axes? [axes? #f]
                                #:spherical-grid? [spherical-grid? #f]
                                #:reference-peak [reference-peak #f]
                                #:color-at [color-at #f]
                                #:radius-at [radius-at #f])
  (unless (nec2c-pattern-grid? grid)
    (raise-argument-error 'radiation-grid->pict3d "nec2c-pattern-grid?" grid))
  (unless (and (real? floor-db) (< floor-db 0))
    (raise-argument-error 'radiation-grid->pict3d "negative-real?" floor-db))
  (unless (and (real? mesh-step) (positive? mesh-step))
    (raise-argument-error 'radiation-grid->pict3d "positive-real?" mesh-step))
  (unless (boolean? axes?)
    (raise-argument-error 'radiation-grid->pict3d "boolean?" axes?))
  (unless (boolean? spherical-grid?)
    (raise-argument-error 'radiation-grid->pict3d "boolean?" spherical-grid?))
  (validate-color-step 'radiation-grid->pict3d color-step)
  (validate-radial-scale 'radiation-grid->pict3d radial-scale)
  (define color-stops
    (or supplied-color-stops
        (resolve-palette 'radiation-grid->pict3d palette)))
  (define samples (nec2c-pattern-grid-samples grid))
  (define gains
    (filter real?
            (map (lambda (sample) (sample-gain sample component)) samples)))
  (when (null? gains)
    (error 'radiation-grid->pict3d
           "selected gain component has no samples"))
  (define peak (apply max gains))
  (define display-peak (or reference-peak peak))
  (unless (and (real? display-peak) (>= display-peak peak))
    (raise-arguments-error
     'radiation-grid->pict3d
     "reference peak must be at least the selected component's peak"
     "reference peak" display-peak
     "component peak" peak))
  (define table (make-hash))
  (for ([sample (in-list samples)])
    (hash-set! table
               (angle-key (nec2c-pattern-sample-theta-deg sample)
                          (nec2c-pattern-sample-phi-deg sample))
               sample))
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
  (define (radius-for sample theta phi)
    (define gain (sample-gain sample component))
    (cond [radius-at (radius-at theta phi)]
          [(real? gain)
           (scaled-radius gain display-peak floor-db normalize? radial-scale)]
          [else 0]))
  (define (relative-gain-at theta-deg phi-deg)
    (define gain (sample-gain (grid-sample theta-deg phi-deg) component))
    (if (real? gain) (- gain display-peak) -30))
  (define (make-surface-vertex theta-deg phi-deg [face-color-db #f])
    (define sample (grid-sample theta-deg phi-deg))
    (define radius (radius-for sample theta-deg phi-deg))
    (define direction (sample-direction sample))
    (define nx (vector-ref direction 0))
    (define ny (vector-ref direction 1))
    (define nz (vector-ref direction 2))
    (define rgb
      (if color-at
          (color-at theta-deg phi-deg)
          (relative-gain-color
           (color-gain
            (if face-color-db
                face-color-db
                (relative-gain-at theta-deg phi-deg))
            color-step)
           color-stops)))
    (vertex (pos (* radius nx) (* radius ny) (* radius nz))
            #:normal (dir nx ny nz)
            #:color (apply rgba
                           (map (lambda (channel) (/ channel 255.0)) rgb))
            ;; A mostly ambient material preserves the data colors while a
            ;; little diffuse response keeps the shape visually legible.
            #:material surface-material))
  (define (make-surface-triangle a b c)
    (define face-color-db
      (and (not color-at) color-step
           (/ (+ (relative-gain-at (first a) (second a))
                 (relative-gain-at (first b) (second b))
                 (relative-gain-at (first c) (second c)))
              3)))
    (triangle (make-surface-vertex (first a) (second a) face-color-db)
              (make-surface-vertex (first b) (second b) face-color-db)
              (make-surface-vertex (first c) (second c) face-color-db)))
  (define surface-triangles
    (append*
     (for*/list ([theta-index (in-range (sub1 (length theta-values)))]
                 [phi-index (in-range (length phi-values))])
       (define theta-a (list-ref theta-values theta-index))
       (define theta-b (list-ref theta-values (add1 theta-index)))
       (define phi-a (list-ref phi-values phi-index))
       (define phi-b
         (if (= phi-index (sub1 (length phi-values)))
             (+ 360 (first phi-values))
             (list-ref phi-values (add1 phi-index))))
       (cond
         [(zero? theta-a)
          (list (make-surface-triangle
                 (list theta-a phi-a)
                 (list theta-b phi-a)
                 (list theta-b phi-b)))]
         [(= theta-b 180)
          (list (make-surface-triangle
                 (list theta-a phi-a)
                 (list theta-b phi-a)
                 (list theta-a phi-b)))]
         [else
          (list (make-surface-triangle
                 (list theta-a phi-a)
                 (list theta-b phi-a)
                 (list theta-b phi-b))
                (make-surface-triangle
                 (list theta-a phi-a)
                 (list theta-b phi-b)
                 (list theta-a phi-b)))]))))

  ;; NEC returns only the upper hemisphere when ground is active. Close its
  ;; horizon ring with a downward-facing fan so back-face culling reveals a
  ;; solid underside instead of the hollow radiation surface.
  (define cap-triangles
    (if (ground-horizon? theta-values)
        (let ([theta (last theta-values)])
          (define (rgb-at gain-db)
            (relative-gain-color (color-gain gain-db color-step) color-stops))
          (define (make-center [face-color-db #f])
            (define rgb
              (if color-at
                  (color-at #f #f)
                  (rgb-at (or face-color-db -30))))
            (vertex (pos 0 0 0)
                    #:normal (dir 0 0 -1)
                    #:color (apply rgba
                                   (map (lambda (channel) (/ channel 255.0))
                                        rgb))
                    #:material surface-material))
          (define (make-rim-vertex phi-deg [face-color-db #f])
            (define sample (grid-sample theta phi-deg))
            (define radius (radius-for sample theta phi-deg))
            (define phi (degrees->radians phi-deg))
            (define gain (sample-gain sample component))
            (define rgb
              (if color-at
                  (color-at theta phi-deg)
                  (rgb-at
                   (if face-color-db
                       face-color-db
                       (if (real? gain) (- gain display-peak) -30)))))
            (vertex (pos (* radius (cos phi)) (* radius (sin phi)) 0)
                    #:normal (dir 0 0 -1)
                    #:color (apply rgba
                                   (map (lambda (channel) (/ channel 255.0))
                                        rgb))
                    #:material surface-material))
          (for/list ([phi-index (in-range (length phi-values))])
            (define phi-a (list-ref phi-values phi-index))
            (define phi-b
              (if (= phi-index (sub1 (length phi-values)))
                  (+ 360 (first phi-values))
                  (list-ref phi-values (add1 phi-index))))
            (define face-color-db
              (and (not color-at) color-step
                   (/ (+ (relative-gain-at theta phi-a)
                         (relative-gain-at theta phi-b))
                      2)))
            ;; Reversed rim order gives the cap an outward (-Z) normal.
            (triangle (make-center face-color-db)
                      (make-rim-vertex phi-b face-color-db)
                      (make-rim-vertex phi-a face-color-db))))
        '()))
  (define triangles (append surface-triangles cap-triangles))
  ;; Center the camera on the middle of the pattern's bounds, not the RF
  ;; origin. This minimizes wasted framing for strongly asymmetric patterns
  ;; while keeping the center stable throughout an orbit.
  (define surface-points
    (for/list ([sample (in-list samples)])
      (define theta (nec2c-pattern-sample-theta-deg sample))
      (define phi (nec2c-pattern-sample-phi-deg sample))
      (define radius (radius-for sample theta phi))
      (define direction (sample-direction sample))
      (vector (* radius (vector-ref direction 0))
              (* radius (vector-ref direction 1))
              (* radius (vector-ref direction 2)))))
  (define (coordinate-values index)
    (map (lambda (point) (vector-ref point index)) surface-points))
  (define xs (coordinate-values 0))
  (define ys (coordinate-values 1))
  (define zs (coordinate-values 2))
  (define center-x (/ (+ (apply min xs) (apply max xs)) 2))
  (define center-y (/ (+ (apply min ys) (apply max ys)) 2))
  (define center-z (/ (+ (apply min zs) (apply max zs)) 2))
  (define view-center (pos center-x center-y center-z))
  (define view-radius
    (max 1e-9
         (apply max
                (for/list ([point (in-list surface-points)])
                  (sqrt (+ (sqr (- (vector-ref point 0) center-x))
                           (sqr (- (vector-ref point 1) center-y))
                           (sqr (- (vector-ref point 2) center-z))))))))
  (define surface (freeze (combine triangles)))
  ;; This deliberately follows the radiation surface instead of drawing a
  ;; reference sphere through it.  The latitude/longitude net therefore adds
  ;; shape cues without implying that radius is an angular coordinate.
  (define spherical-grid
    (if spherical-grid?
        (let* ([close-phi-values
                (append phi-values (list (+ 360 (first phi-values))))]
               [near-multiple?
                (lambda (value step)
                  (< (abs (- value (* step (round (/ value step))))) 1e-7))]
               [grid-phis (filter (lambda (value) (near-multiple? value 30))
                                  phi-values)]
               [grid-thetas
                (filter (lambda (value)
                          (and (> value 0) (< value 180)
                               (near-multiple? value 15)))
                        theta-values)]
               [line-radius (* view-radius 0.0022)]
               [surface-point
                (lambda (theta phi)
                  (define sample (grid-sample theta phi))
                  (define radius (* 1.004 (radius-for sample theta phi)))
                  (define direction (sample-direction sample))
                  (pos (* radius (vector-ref direction 0))
                       (* radius (vector-ref direction 1))
                       (* radius (vector-ref direction 2))))]
               [join-points
                (lambda (points)
                  (for/list ([a (in-list points)]
                             [b (in-list (rest points))]
                             #:when (> (pos-dist a b) (* line-radius 0.25)))
                    (pipe a b
                          #:bottom-radii (interval 0 line-radius)
                          #:top-radii (interval 0 line-radius))))]
               [segments
                (append*
                 (append
                  (for/list ([phi (in-list grid-phis)])
                    (join-points
                     (for/list ([theta (in-list theta-values)])
                       (surface-point theta phi))))
                  (for/list ([theta (in-list grid-thetas)])
                    (join-points
                     (for/list ([phi (in-list close-phi-values)])
                       (surface-point theta phi))))))])
          (freeze
           (with-color (rgba 0.32 0.88 1.0 0.72)
             (with-emitted (emitted 0.20 0.80 1.0 0.35)
               (combine segments)))))
        empty-pict3d))
  (define decorated-surface
    (if spherical-grid?
        (freeze (combine surface spherical-grid))
        surface))
  (values (if axes?
              (freeze (combine decorated-surface (coordinate-triad view-radius)))
              decorated-surface)
          view-radius
          view-center
          peak))

(define (radiation-grid->pict3d grid
                                #:component [component 'total]
                                #:floor-db [floor-db -40]
                                #:normalize? [normalize? #t]
                                #:scale [radial-scale 'arrl]
                                #:palette [palette 'mmana]
                                #:color-step [color-step #f]
                                #:mesh-step [mesh-step 2]
                                #:axes? [axes? #f])
  (define-values (surface radius _center _peak)
    (build-radiation-pict3d grid
                            #:component component
                            #:floor-db floor-db
                            #:normalize? normalize?
                            #:scale radial-scale
                            #:palette palette
                            #:color-step color-step
                            #:mesh-step mesh-step
                            #:axes? axes?))
  (values surface radius))

(define (camera-scene surface view-center radius azimuth altitude zoom)
  (define az (degrees->radians azimuth))
  (define alt (degrees->radians altitude))
  (define distance (* radius zoom))
  (define camera-position
    (pos (+ (pos-x view-center) (* distance (cos alt) (cos az)))
         (+ (pos-y view-center) (* distance (cos alt) (sin az)))
         (+ (pos-z view-center) (* distance (sin alt)))))
  (combine surface
           (basis 'camera (point-at camera-position view-center))))

(define view-fov-degrees 34)

(define (project-direction x y z azimuth altitude)
  (define az (degrees->radians azimuth))
  (define alt (degrees->radians altitude))
  ;; Camera screen-right, screen-down, and origin-to-camera components.
  (values (+ (* x (- (sin az))) (* y (cos az)))
          (+ (* x (sin alt) (cos az))
             (* y (sin alt) (sin az))
             (* z (- (cos alt))))
          (+ (* x (cos alt) (cos az))
             (* y (cos alt) (sin az))
             (* z (sin alt)))))

;; Keep orientation information out of the depth-tested radiation scene. A
;; small 2-D triad cannot be clipped or hidden by the model, and an axis aimed
;; directly at the camera can be represented by a dot instead of disappearing.
(define orientation-canvas%
  (class canvas%
    (init-field [azimuth -42.0] [altitude 24.0])
    (super-new [min-width 104]
               [min-height 88]
               [stretchable-width #f]
               [stretchable-height #f]
               [style '(border)])
    (define/public (set-orientation new-azimuth new-altitude)
      (set! azimuth new-azimuth)
      (set! altitude new-altitude)
      (send this refresh))
    (define/private (draw-axis dc ox oy scale dx dy color label fallback-dx fallback-dy)
      (define projected-length (sqrt (+ (* dx dx) (* dy dy))))
      (send dc set-pen color 3 'solid)
      (send dc set-brush color 'solid)
      (cond
        [(< projected-length 0.08)
         ;; Looking almost exactly along an axis has no well-defined projected
         ;; direction. A colored bullseye keeps that axis present and honest.
         (send dc draw-ellipse (- ox 4) (- oy 4) 8 8)
         (send dc set-brush "white" 'solid)
         (send dc draw-ellipse (- ox 1) (- oy 1) 2 2)
         (send dc draw-text label
               (+ ox (* 10 fallback-dx) -4)
               (+ oy (* 10 fallback-dy) -8))]
        [else
         (define ux (/ dx projected-length))
         (define uy (/ dy projected-length))
         (define ex (+ ox (* scale dx)))
         (define ey (+ oy (* scale dy)))
         (define px (- uy))
         (define py ux)
         (send dc draw-line ox oy ex ey)
         (send dc draw-polygon
               (list (make-object point% ex ey)
                     (make-object point%
                                  (- ex (* 8 ux) (* 4 px))
                                  (- ey (* 8 uy) (* 4 py)))
                     (make-object point%
                                  (- ex (* 8 ux) (* -4 px))
                                  (- ey (* 8 uy) (* -4 py)))))
         (send dc draw-text label (+ ex (* 7 ux) -4) (+ ey (* 7 uy) -8))]))
    (define/override (on-paint)
      (define dc (send this get-dc))
      (define-values (width height) (send dc get-size))
      (send dc set-background (make-object color% 248 248 248))
      (send dc clear)
      (send dc set-smoothing 'smoothed)
      (send dc set-text-foreground "black")
      ;; These are the dot products of the world axes with the camera's screen
      ;; right and screen down vectors. The camera always looks at the origin.
      (define-values (x-dx x-dy _x-depth)
        (project-direction 1 0 0 azimuth altitude))
      (define-values (y-dx y-dy _y-depth)
        (project-direction 0 1 0 azimuth altitude))
      (define-values (z-dx z-dy _z-depth)
        (project-direction 0 0 1 azimuth altitude))
      (define projections
        (list (list x-dx x-dy
                    (make-object color% 215 45 45) "X" 1 0)
              (list y-dx y-dy
                    (make-object color% 40 90 220) "Y" -1 0)
              (list z-dx z-dy
                    (make-object color% 20 150 65) "Z" 0 -1)))
      (define ox (/ width 2.0))
      (define oy (/ height 2.0))
      (define scale (* 0.34 (min width height)))
      (for ([axis (in-list projections)])
        (draw-axis dc ox oy scale
                   (list-ref axis 0)
                   (list-ref axis 1)
                   (list-ref axis 2)
                   (list-ref axis 3)
                   (list-ref axis 4)
                   (list-ref axis 5)))
      (send dc set-pen "black" 1 'solid)
      (send dc set-brush "black" 'solid)
      (send dc draw-ellipse (- ox 2) (- oy 2) 4 4))))

(define antenna-inset-canvas%
  (class canvas%
    (init-field edges [azimuth -42.0] [altitude 24.0])
    (super-new [min-width 140]
               [min-height 88]
               [stretchable-width #f]
               [stretchable-height #f]
               [style '(border)])
    (define points '())
    (define center-x 0)
    (define center-y 0)
    (define center-z 0)
    (define model-radius 1)
    (define (coordinate-values accessor)
      (map accessor points))
    (define/private (recalculate-geometry!)
      (set! points
            (append*
             (for/list ([edge (in-list edges)])
               (list (vertex-point (wire-edge-start edge))
                     (vertex-point (wire-edge-end edge))))))
      (define (axis-center accessor)
        (if (null? points) 0
            (/ (+ (apply min (coordinate-values accessor))
                  (apply max (coordinate-values accessor)))
               2)))
      (set! center-x (axis-center point3-x))
      (set! center-y (axis-center point3-y))
      (set! center-z (axis-center point3-z))
      (set! model-radius
            (max 1e-12
                 (if (null? points)
                     1
                     (apply max
                            (for/list ([point (in-list points)])
                              (sqrt
                               (+ (sqr (- (point3-x point) center-x))
                                  (sqr (- (point3-y point) center-y))
                                  (sqr (- (point3-z point) center-z))))))))))
    (recalculate-geometry!)
    (define/public (set-edges new-edges)
      (set! edges new-edges)
      (recalculate-geometry!)
      (send this refresh))
    (define/public (set-orientation new-azimuth new-altitude)
      (set! azimuth new-azimuth)
      (set! altitude new-altitude)
      (send this refresh))
    (define/private (project-point point ox oy scale)
      (define-values (screen-x screen-y _depth)
        (project-direction (- (point3-x point) center-x)
                           (- (point3-y point) center-y)
                           (- (point3-z point) center-z)
                           azimuth altitude))
      (values (+ ox (* scale screen-x))
              (+ oy (* scale screen-y))))
    (define/private (feed-point edge)
      (define start (vertex-point (wire-edge-start edge)))
      (define end (vertex-point (wire-edge-end edge)))
      (case (wire-edge-feed-location edge)
        [(start) start]
        [(end) end]
        [else
         (point3 (/ (+ (point3-x start) (point3-x end)) 2)
                 (/ (+ (point3-y start) (point3-y end)) 2)
                 (/ (+ (point3-z start) (point3-z end)) 2))]))
    (define/override (on-paint)
      (define dc (send this get-dc))
      (define-values (width height) (send dc get-size))
      (send dc set-background (make-object color% 248 248 248))
      (send dc clear)
      (send dc set-smoothing 'smoothed)
      (send dc set-text-foreground (make-object color% 80 80 80))
      (send dc draw-text "antenna" 6 4)
      (cond
        [(null? edges)
         (send dc draw-text "no geometry" 24 (- (/ height 2) 7))]
        [else
         (define ox (/ width 2.0))
         (define oy (+ 8 (/ height 2.0)))
         (define scale (/ (* 0.40 (min width (- height 12))) model-radius))
         (send dc set-pen (make-object color% 40 100 170) 2 'solid)
         (for ([edge (in-list edges)])
           (define-values (x1 y1)
             (project-point (vertex-point (wire-edge-start edge)) ox oy scale))
           (define-values (x2 y2)
             (project-point (vertex-point (wire-edge-end edge)) ox oy scale))
           (send dc draw-line x1 y1 x2 y2))
         (send dc set-pen (make-object color% 205 35 35) 1 'solid)
         (send dc set-brush (make-object color% 225 45 45) 'solid)
         (for ([edge (in-list edges)] #:when (wire-edge-feed? edge))
           (define-values (x y)
             (project-point (feed-point edge) ox oy scale))
           (send dc draw-ellipse (- x 4) (- y 4) 8 8))]))))

(define legend-canvas%
  (class canvas%
    (init-field radial-scale palette color-stops peak-gain color-step)
    (super-new [min-width 210]
               [stretchable-width #f]
               [style '(border)])
    (define/public (set-peak-gain new-peak-gain)
      (set! peak-gain new-peak-gain)
      (send this refresh))
    (define/public (set-palette new-palette new-color-stops)
      (set! palette new-palette)
      (set! color-stops new-color-stops)
      (send this refresh))
    (define/override (on-paint)
      (define dc (send this get-dc))
      (define-values (width height) (send dc get-size))
      (send dc set-background (make-object color% 248 248 248))
      (send dc clear)
      (send dc set-text-foreground "black")
      (send dc draw-text "gain: dBi | relative" 10 8)
      (send dc draw-text
            (format "~a / ~a~a"
                    palette radial-scale
                    (if color-step (format " / ~a dB bands" color-step) ""))
            10 27)
      (define top 54)
      (define bottom (- height 38))
      (define bar-left 88)
      (define bar-width 28)
      (define bar-height (max 1 (- bottom top)))
      (for ([offset (in-range bar-height)])
        (define gain-db (* -30 (/ offset (max 1 (sub1 bar-height)))))
        (define rgb
          (relative-gain-color (color-gain gain-db color-step) color-stops))
        (send dc set-pen "transparent" 0 'transparent)
        (send dc set-brush
              (apply make-object color% (map exact-round rgb)) 'solid)
        (send dc draw-rectangle bar-left (+ top offset) bar-width 1))
      (send dc set-pen "black" 1 'solid)
      (send dc set-brush "transparent" 'transparent)
      (send dc draw-rectangle bar-left top bar-width bar-height)
      (for ([gain-db (in-list '(0 -3 -6 -10 -20 -30))])
        (define y (+ top (* (/ (- gain-db) 30) bar-height)))
        (define absolute-label
          (format "~a dBi"
                  (real->decimal-string
                   (exact->inexact (+ peak-gain gain-db)) 1)))
        (define-values (label-width _label-height _descent _space)
          (send dc get-text-extent absolute-label))
        (send dc draw-line (- bar-left 5) y bar-left y)
        (send dc draw-text absolute-label
              (- bar-left label-width 9) (- y 8))
        (send dc draw-line (+ bar-left bar-width) y
              (+ bar-left bar-width 5) y)
        (send dc draw-text (format "~a dB" gain-db)
              (+ bar-left bar-width 9) (- y 8))))))

(define orbit-canvas%
  (class pict3d-canvas%
    (init-field surface view-center radius orientation-canvas antenna-canvas
                status-label)
    (define azimuth -42.0)
    (define altitude 24.0)
    (define zoom 3.1)
    (define dragging? #f)
    (define previous-x 0)
    (define previous-y 0)
    (define display-scene surface)
    (super-new [pict3d (camera-scene display-scene view-center
                                     radius azimuth altitude zoom)])
    (define/private (update-view!)
      (when orientation-canvas
        (send orientation-canvas set-orientation azimuth altitude))
      (when antenna-canvas
        (send antenna-canvas set-orientation azimuth altitude))
      (send status-label set-label
            (format "drag to orbit  |  wheel to zoom  |  azimuth ~a°  elevation ~a°"
                    (exact-round azimuth) (exact-round altitude)))
      (parameterize ([current-pict3d-background (rgba "black")]
                     [current-pict3d-ambient (emitted "white" 1.0)]
                     [current-pict3d-fov view-fov-degrees])
        (send this set-pict3d
              (camera-scene display-scene view-center
                            radius azimuth altitude zoom))))
    (define/public (replace-scene new-surface new-view-center new-radius)
      (set! surface new-surface)
      (set! display-scene new-surface)
      (set! view-center new-view-center)
      (set! radius new-radius)
      (update-view!))
    (define/override (on-event event)
      (define type (send event get-event-type))
      (define x (send event get-x))
      (define y (send event get-y))
      (case type
        [(left-down)
         (set! dragging? #t)
         (set! previous-x x)
         (set! previous-y y)]
        [(left-up) (set! dragging? #f)]
        [(motion)
         (when dragging?
           ;; Treat the surface as grabbed: moving the pointer moves the
           ;; front-most face in the same screen direction. This is the
           ;; inverse of directly orbiting the camera.
           (set! azimuth (- azimuth (* 0.45 (- x previous-x))))
           (set! altitude
                 (max -89.0
                      (min 89.0
                           (+ altitude (* 0.45 (- y previous-y))))))
           (set! previous-x x)
           (set! previous-y y)
           (update-view!))]
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

;; The comparison viewer shares camera state but gives each pattern its own
;; center. All canvases receive the same world-space radius, so relative size
;; remains meaningful instead of every antenna being independently enlarged.
(struct comparison-view (host surface proxy) #:transparent)

(define comparison-controller%
  (class object%
    (init-field orientation-canvas status-label)
    (super-new)
    (define azimuth -42.0)
    (define altitude 24.0)
    (define zoom 3.1)
    (define dragging? #f)
    (define previous-x 0)
    (define previous-y 0)
    (define views '())
    (define/public (initial-azimuth) azimuth)
    (define/public (initial-altitude) altitude)
    (define/public (initial-zoom) zoom)
    (define/public (drag-active?) dragging?)
    (define/public (register host surface proxy)
      (set! views (cons (comparison-view host surface proxy) views)))
    (define/private (update-all!)
      (send orientation-canvas set-orientation azimuth altitude)
      (send status-label set-label
            (format "~adrag any pattern to orbit  |  wheel to zoom  |  azimuth ~a°  elevation ~a°"
                    (if dragging? "wireframe  |  " "")
                    (exact-round azimuth) (exact-round altitude)))
      (for ([view (in-list views)])
        (send (if dragging?
                  (comparison-view-proxy view)
                  (comparison-view-surface view))
              set-shared-view azimuth altitude zoom)))
    (define/public (refresh-view) (update-all!))
    (define/public (begin-drag x y)
      (unless dragging?
        (set! dragging? #t)
        (set! previous-x x)
        (set! previous-y y)
        (for ([view (in-list views)])
          (send (comparison-view-host view)
                change-children
                (lambda (_children) (list (comparison-view-proxy view)))))
        (update-all!)))
    (define/public (end-drag)
      (when dragging?
        (set! dragging? #f)
        (for ([view (in-list views)])
          (send (comparison-view-host view)
                change-children
                (lambda (_children) (list (comparison-view-surface view)))))
        ;; One final high-detail redraw lands on the exact requested view.
        (update-all!)))
    (define/public (drag-to x y)
      ;; Match the single-pattern viewer's grab-the-surface interaction.
      (set! azimuth (- azimuth (* 0.45 (- x previous-x))))
      (set! altitude
            (max -89.0
                 (min 89.0 (+ altitude (* 0.45 (- y previous-y))))))
      (set! previous-x x)
      (set! previous-y y)
      (update-all!))
    (define/public (zoom-in)
      (set! zoom (max 1.25 (* zoom 0.88)))
      (update-all!))
    (define/public (zoom-out)
      (set! zoom (min 20.0 (/ zoom 0.88)))
      (update-all!))))

(define comparison-orbit-canvas%
  (class pict3d-canvas%
    (init-field surface view-center radius controller)
    (super-new
     [pict3d
      (camera-scene surface view-center radius
                    (send controller initial-azimuth)
                    (send controller initial-altitude)
                    (send controller initial-zoom))])
    (define/public (replace-scene new-surface new-view-center new-radius)
      (set! surface new-surface)
      (set! view-center new-view-center)
      (set! radius new-radius))
    (define/public (set-shared-view azimuth altitude zoom)
      (parameterize ([current-pict3d-background (rgba "black")]
                     [current-pict3d-ambient (emitted "white" 1.0)]
                     [current-pict3d-fov view-fov-degrees])
        (send this set-pict3d
              (camera-scene surface view-center radius
                            azimuth altitude zoom))))
    (define/override (on-event event)
      (define type (send event get-event-type))
      (define x (send event get-x))
      (define y (send event get-y))
      (case type
        [(left-down)
         (send controller begin-drag x y)]
        [(left-up) (send controller end-drag)]
        [(motion)
         (cond [(send event get-left-down)
                (send controller drag-to x y)]
               [(send controller drag-active?)
                (send controller end-drag)])]
        [(wheel-up) (send controller zoom-in)]
        [(wheel-down) (send controller zoom-out)]
        [else (void)]))
    (define/override (on-char event)
      (case (send event get-key-code)
        [(wheel-up #\+) (send controller zoom-in)]
        [(wheel-down #\-) (send controller zoom-out)]
        [else (void)]))))

;; The interaction proxy intentionally bypasses OpenGL. It projects a sparse
;; latitude/longitude net with ordinary 2-D drawing, including far-side lines.
;; Six or nine tiles can therefore follow the pointer without filling six or
;; nine independent OpenGL command queues.
(define comparison-proxy-canvas%
  (class canvas%
    (init-field polylines view-center radius controller)
    (define azimuth -42.0)
    (define altitude 24.0)
    (define zoom 3.1)
    (super-new [style '(border)])
    (define/public (replace-polylines new-polylines new-view-center new-radius)
      (set! polylines new-polylines)
      (set! view-center new-view-center)
      (set! radius new-radius))
    (define/public (set-shared-view new-azimuth new-altitude new-zoom)
      (set! azimuth new-azimuth)
      (set! altitude new-altitude)
      (set! zoom new-zoom)
      (send this refresh))
    (define/private (project point width height)
      (define-values (screen-x screen-y _depth)
        (project-direction
         (- (vector-ref point 0) (pos-x view-center))
         (- (vector-ref point 1) (pos-y view-center))
         (- (vector-ref point 2) (pos-z view-center))
         azimuth altitude))
      (define scale
        (/ (* 1.38 (min width height)) (* radius zoom)))
      (make-object point%
                   (+ (/ width 2.0) (* scale screen-x))
                   (+ (/ height 2.0) (* scale screen-y))))
    (define/override (on-paint)
      (define dc (send this get-dc))
      (define-values (width height) (send dc get-size))
      (send dc set-background "black")
      (send dc clear)
      (send dc set-smoothing 'smoothed)
      (send dc set-pen (make-object color% 35 110 220) 1 'solid)
      (for ([polyline (in-list polylines)])
        (send dc draw-lines
              (for/list ([point (in-list polyline)])
                (project point width height)))))
    (define/override (on-event event)
      (define type (send event get-event-type))
      (define x (send event get-x))
      (define y (send event get-y))
      (case type
        [(left-down) (send controller begin-drag x y)]
        [(left-up) (send controller end-drag)]
        [(motion)
         (cond [(send event get-left-down)
                (send controller drag-to x y)]
               [(send controller drag-active?)
                (send controller end-drag)])]
        [(wheel-up) (send controller zoom-in)]
        [(wheel-down) (send controller zoom-out)]
        [else (void)]))))

(define horizontal-legend-canvas%
  (class canvas%
    (init-field radial-scale palette color-stops peak-gain color-step)
    (super-new [min-height 82]
               [stretchable-width #t]
               [stretchable-height #f]
               [style '(border)])
    (define/public (set-peak-gain new-peak-gain)
      (set! peak-gain new-peak-gain)
      (send this refresh))
    (define/override (on-paint)
      (define dc (send this get-dc))
      (define-values (width height) (send dc get-size))
      (send dc set-background (make-object color% 248 248 248))
      (send dc clear)
      (send dc set-text-foreground "black")
      (define heading
        (format "shared gain — ~a / ~a~a"
                palette radial-scale
                (if color-step (format " / ~a dB bands" color-step) "")))
      (define-values (heading-width _heading-height _descent _space)
        (send dc get-text-extent heading))
      (send dc draw-text heading 8 7)
      ;; Text is measured rather than assigned a fixed column, keeping the
      ;; legend compact under large desktop font settings.
      (define bar-left (+ 20 heading-width))
      (define bar-right (max (+ bar-left 40) (- width 18)))
      (define bar-top 30)
      (define bar-height 18)
      (define bar-width (max 1 (- bar-right bar-left)))
      (for ([offset (in-range bar-width)])
        (define relative-db (* -30 (/ offset (max 1 (sub1 bar-width)))))
        (define rgb
          (relative-gain-color
           (color-gain relative-db color-step) color-stops))
        (send dc set-pen "transparent" 0 'transparent)
        (send dc set-brush
              (apply make-object color% (map exact-round rgb)) 'solid)
        (send dc draw-rectangle (+ bar-left offset) bar-top 1 bar-height))
      (send dc set-pen "black" 1 'solid)
      (send dc set-brush "transparent" 'transparent)
      (send dc draw-rectangle bar-left bar-top bar-width bar-height)
      (define ticks
        (cond [(>= bar-width 500) '(0 -3 -6 -10 -20 -30)]
              [(>= bar-width 300) '(0 -6 -10 -20 -30)]
              [else '(0 -10 -20 -30)]))
      (for ([relative-db (in-list ticks)])
        (define fraction (/ (- relative-db) 30))
        (define x (+ bar-left (* fraction bar-width)))
        (define relative-label (format "~a dB" relative-db))
        (define absolute-label
          (format "~a dBi"
                  (real->decimal-string
                   (exact->inexact (+ peak-gain relative-db)) 1)))
        (define-values (relative-width _rh _rd _rs)
          (send dc get-text-extent relative-label))
        (define-values (absolute-width _ah _ad _as)
          (send dc get-text-extent absolute-label))
        (define (bounded-label-x label-width)
          (max bar-left
               (min (- bar-right label-width)
                    (- x (/ label-width 2)))))
        (send dc draw-line x (- bar-top 4) x bar-top)
        (send dc draw-text relative-label
              (bounded-label-x relative-width) 11)
        (send dc draw-line x (+ bar-top bar-height) x
              (+ bar-top bar-height 4))
        (send dc draw-text absolute-label
              (bounded-label-x absolute-width) 52)))))

(define difference-legend-canvas%
  (class canvas%
    (init-field range-db)
    (super-new [min-height 62]
               [stretchable-width #t]
               [stretchable-height #f]
               [style '(border)])
    (define/public (set-range-db new-range-db)
      (set! range-db new-range-db)
      (send this refresh))
    (define/override (on-paint)
      (define dc (send this get-dc))
      (define-values (width _height) (send dc get-size))
      (send dc set-background (make-object color% 248 248 248))
      (send dc clear)
      (send dc set-text-foreground "black")
      (define heading "candidate − reference · absolute gain difference")
      (define-values (heading-width _hh _hd _hs)
        (send dc get-text-extent heading))
      (send dc draw-text heading 8 5)
      (define bar-left (+ 20 heading-width))
      (define bar-right (max (+ bar-left 40) (- width 18)))
      (define bar-top 24)
      (define bar-height 16)
      (define bar-width (max 1 (- bar-right bar-left)))
      (for ([offset (in-range bar-width)])
        (define difference-db
          (+ (- range-db)
             (* 2 range-db (/ offset (max 1 (sub1 bar-width))))))
        (define rgb (difference-color difference-db range-db))
        (send dc set-pen "transparent" 0 'transparent)
        (send dc set-brush
              (apply make-object color% (map exact-round rgb)) 'solid)
        (send dc draw-rectangle (+ bar-left offset) bar-top 1 bar-height))
      (send dc set-pen "black" 1 'solid)
      (send dc set-brush "transparent" 'transparent)
      (send dc draw-rectangle bar-left bar-top bar-width bar-height)
      (for ([difference-db (in-list (list (- range-db) 0 range-db))]
            [fraction (in-list '(0 1/2 1))])
        (define x (+ bar-left (* fraction bar-width)))
        (define label
          (format "~a~a dB"
                  (if (positive? difference-db) "+" "")
                  (real->decimal-string (exact->inexact difference-db) 1)))
        (define-values (label-width _lh _ld _ls)
          (send dc get-text-extent label))
        (send dc draw-line x (+ bar-top bar-height) x
              (+ bar-top bar-height 4))
        (send dc draw-text label
              (max bar-left
                   (min (- bar-right label-width)
                        (- x (/ label-width 2))))
              43)))))

(define (comparison-layout count width height [footer-height 112])
  (define usable-height (max 1 (- height footer-height)))
  (define candidates
    (for/list ([columns (in-range 1 (add1 count))])
      (define rows (ceiling (/ count columns)))
      (define tile-aspect
        (/ (/ width columns) (/ usable-height rows)))
      (define empty (- (* rows columns) count))
      (list (+ (abs (log tile-aspect)) (* 0.18 empty)) rows columns)))
  (define best (argmin first candidates))
  (values (second best) (third best)))

(define (component-peak grid component)
  (define gains
    (filter real?
            (for/list ([sample (in-list (nec2c-pattern-grid-samples grid))])
              (sample-gain sample component))))
  (when (null? gains)
    (error 'show-radiation-comparison
           "selected gain component has no samples"))
  (apply max gains))

(define (grid-angle-signature grid)
  (list (map (lambda (theta) (angle-key theta 0))
             (nec2c-pattern-grid-theta-values grid))
        (map (lambda (phi) (angle-key 0 phi))
             (nec2c-pattern-grid-phi-values grid))))

(define (validate-difference-grids who cases)
  (when (< (length cases) 2)
    (raise-arguments-error
     who "difference rendering requires a reference and at least one candidate"
     "cases" (length cases)))
  (define reference-signature
    (grid-angle-signature (radiation-case-grid (first cases))))
  (for ([item (in-list (rest cases))]
        [index (in-naturals 2)])
    (unless (equal? reference-signature
                    (grid-angle-signature (radiation-case-grid item)))
      (raise-arguments-error
       who
       "difference rendering requires identical theta and phi sample grids"
       "reference case" (radiation-case-title (first cases))
       "incompatible case" (radiation-case-title item)
       "case position" index))))

(define (grid-gain-table grid component)
  (for/hash ([sample (in-list (nec2c-pattern-grid-samples grid))])
    (values (angle-key (nec2c-pattern-sample-theta-deg sample)
                       (nec2c-pattern-sample-phi-deg sample))
            (sample-gain sample component))))

(define (difference-color-function reference-grid candidate-grid component range-db)
  (define reference-table (grid-gain-table reference-grid component))
  (define candidate-table (grid-gain-table candidate-grid component))
  (lambda (theta phi)
    (cond
      [(not theta) (difference-color 0 range-db)]
      [else
       (define normalized-phi
         (- phi (* 360 (floor (/ phi 360)))))
       (define key (angle-key theta normalized-phi))
       (define reference-gain (hash-ref reference-table key #f))
       (define candidate-gain (hash-ref candidate-table key #f))
       (difference-color
        (if (and (real? reference-gain) (real? candidate-gain))
            (- candidate-gain reference-gain)
            0)
        range-db)])))

;; Subtract the two already-scaled display surfaces rather than attempting to
;; assign a direction to a negative radius. Magnitude becomes radius and the
;; diverging difference color retains the sign. This inherits the selected
;; ARRL/dB radial scale and its handling of deep nulls.
(define (difference-radius-function reference-grid candidate-grid component
                                    floor-db radial-scale reference-peak)
  (define reference-table (grid-gain-table reference-grid component))
  (define candidate-table (grid-gain-table candidate-grid component))
  (lambda (theta phi)
    (define normalized-phi
      (- phi (* 360 (floor (/ phi 360)))))
    (define key (angle-key theta normalized-phi))
    (define reference-gain (hash-ref reference-table key #f))
    (define candidate-gain (hash-ref candidate-table key #f))
    (if (and (real? reference-gain) (real? candidate-gain))
        (abs (- (scaled-radius candidate-gain reference-peak floor-db #t radial-scale)
                (scaled-radius reference-gain reference-peak floor-db #t radial-scale)))
        0)))

(define (automatic-difference-range cases component)
  (define reference-grid (radiation-case-grid (first cases)))
  (define reference-table (grid-gain-table reference-grid component))
  (define reference-peak (component-peak reference-grid component))
  ;; Differences in deep nulls can be arbitrarily large in dB while carrying
  ;; negligible field energy. Restrict auto-ranging to the same 30 dB region
  ;; represented by the ordinary comparison color legend.
  (define visible-floor (- reference-peak 30))
  (define differences
    (for*/fold ([result '()])
               ([item (in-list (rest cases))]
                [sample (in-list
                         (nec2c-pattern-grid-samples
                          (radiation-case-grid item)))])
      (define key
        (angle-key (nec2c-pattern-sample-theta-deg sample)
                   (nec2c-pattern-sample-phi-deg sample)))
      (define reference-gain (hash-ref reference-table key #f))
      (define candidate-gain (sample-gain sample component))
      (if (and (real? reference-gain)
               (real? candidate-gain)
               (>= reference-gain visible-floor))
          (cons (abs (- candidate-gain reference-gain)) result)
          result)))
  ;; A small nonzero range keeps exact or nearly identical comparisons from
  ;; magnifying floating-point noise into a dramatic full-scale heat map.
  (max 0.1 (if (null? differences) 0 (apply max differences))))

(define (comparison-proxy-polylines grid component floor-db radial-scale
                                    reference-peak mesh-step [radius-at #f])
  (define samples (nec2c-pattern-grid-samples grid))
  (define table (make-hash))
  (for ([sample (in-list samples)])
    (hash-set! table
               (angle-key (nec2c-pattern-sample-theta-deg sample)
                          (nec2c-pattern-sample-phi-deg sample))
               sample))
  (define theta-values
    (sample-open-angle-values
     (nec2c-pattern-grid-theta-values grid) mesh-step))
  (define phi-values
    (sample-cyclic-angle-values
     (nec2c-pattern-grid-phi-values grid) mesh-step))
  (define (sample-at theta phi)
    (define normalized-phi
      (- phi (* 360 (floor (/ phi 360)))))
    (hash-ref table (angle-key theta normalized-phi)))
  (define (point-at theta-deg phi-deg)
    (define sample (sample-at theta-deg phi-deg))
    (define gain (sample-gain sample component))
    (define radius
      (cond [radius-at (radius-at theta-deg phi-deg)]
            [(real? gain)
             (scaled-radius gain reference-peak floor-db #t radial-scale)]
            [else 0]))
    (define direction (sample-direction sample))
    (vector (* radius (vector-ref direction 0))
            (* radius (vector-ref direction 1))
            (* radius (vector-ref direction 2))))
  (append
   ;; Meridians include both poles (or pole and grounded horizon).
   (for/list ([phi (in-list phi-values)])
     (for/list ([theta (in-list theta-values)])
       (point-at theta phi)))
   ;; Parallels close across the omitted 360-degree seam.
   (for/list ([theta (in-list theta-values)])
     (for/list ([phi (in-list (append phi-values
                                      (list (+ 360 (first phi-values)))))] )
       (point-at theta phi)))))

(define (queue-in-eventspace eventspace thunk)
  (parameterize ([current-eventspace eventspace])
    (queue-callback thunk #f)))

(define (make-opengl-handle frame update-procedure [restage-procedure #f])
  (define handle
    (make-visualization-handle
     update-procedure
     (lambda () (send frame show #t))
     (lambda () (send frame show #f))
     (lambda () (send frame is-shown?))))
  (when restage-procedure
    (set-visualization-handle-restage! handle restage-procedure))
  handle)

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
  (unless (and (exact-integer? width) (positive? width))
    (raise-argument-error 'show-radiation-pattern-opengl
                          "exact-positive-integer?" width))
  (unless (and (exact-integer? height) (positive? height))
    (raise-argument-error 'show-radiation-pattern-opengl
                          "exact-positive-integer?" height))
  (unless (boolean? axes?)
    (raise-argument-error 'show-radiation-pattern-opengl "boolean?" axes?))
  (unless (boolean? antenna?)
    (raise-argument-error 'show-radiation-pattern-opengl "boolean?" antenna?))
  (validate-radial-scale 'show-radiation-pattern-opengl radial-scale)
  (define color-stops
    (resolve-palette 'show-radiation-pattern-opengl palette))
  ;; Keep the most recently requested data so a failed Pict3D context can be
  ;; replaced with a new window without forcing another solver run.
  (define current-grid (box grid))
  (define-values (surface radius view-center peak-gain)
    (build-radiation-pict3d grid
                            #:component component
                            #:floor-db floor-db
                            #:normalize? normalize?
                            #:scale radial-scale
                            #:palette palette
                            #:color-step color-step
                            #:mesh-step mesh-step))
  (define frame
    (new frame%
         [label (format "~a OpenGL radiation pattern"
                        (radiation-backend-title grid))]
         [width width]
         [height height]))
  (define eventspace (current-eventspace))
  (define root (new vertical-panel% [parent frame]))
  (define body (new horizontal-panel% [parent root]))
  (define footer
    (new horizontal-panel%
         [parent root]
         [alignment '(left center)]
         [stretchable-height #f]))
  (define orientation-canvas
    (and axes?
         (new orientation-canvas% [parent footer])))
  (define antenna-canvas
    (and antenna?
         (new antenna-inset-canvas%
              [parent footer]
              [edges (model-edges)])))
  (define status
    (new message%
         [parent footer]
         [label "drag to orbit  |  wheel to zoom"]
         [stretchable-width #t]))
  (define canvas
    (parameterize ([current-pict3d-background (rgba "black")]
                   [current-pict3d-ambient (emitted "white" 1.0)]
                   [current-pict3d-fov view-fov-degrees])
      (new orbit-canvas%
           [parent body]
           [surface surface]
           [view-center view-center]
           [radius radius]
           [orientation-canvas orientation-canvas]
           [antenna-canvas antenna-canvas]
           [status-label status])))
  (send canvas set-async-updates? #t)
  (define legend
    (new legend-canvas%
         [parent body]
         [radial-scale radial-scale]
         [palette palette]
         [color-stops color-stops]
         [peak-gain peak-gain]
         [color-step color-step]))
  (send frame show #t)
  (make-opengl-handle
   frame
   (lambda (new-grid)
     (unless (nec2c-pattern-grid? new-grid)
       (raise-argument-error
        'visualization-update! "nec2c-pattern-grid?" new-grid))
     (set-box! current-grid new-grid)
     ;; Surface construction is the expensive part and deliberately happens
     ;; in the caller's thread. Only widget mutation is queued to the GUI.
     (define-values (new-surface new-radius new-center new-peak)
       (build-radiation-pict3d
        new-grid
        #:component component
        #:floor-db floor-db
        #:normalize? normalize?
        #:scale radial-scale
        #:palette palette
        #:color-step color-step
        #:mesh-step mesh-step))
     (define new-edges (and antenna? (model-edges)))
     (queue-in-eventspace
      eventspace
     (lambda ()
        (send canvas replace-scene new-surface new-center new-radius)
        (send legend set-peak-gain new-peak)
        (when antenna-canvas
          (send antenna-canvas set-edges new-edges)))))
   (lambda ()
     ;; Pict3D owns the render thread and does not provide a supported way to
     ;; revive a failed GL context in place. Hide the failed frame and create a
     ;; new context from the retained grid instead.
     (queue-in-eventspace eventspace (lambda () (send frame show #f)))
     (show-radiation-pattern-opengl
      (unbox current-grid)
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
      #:height height))))

;; Experimental near-field energy-flow workbench. The tracers are visualization
;; probes advected by S/u; they are not conserved photons or charge carriers.
(struct flow-trail-point (u v direction-rgb) #:transparent)
(struct flow-particle (u v trail age direction-rgb energy-rgb) #:mutable)

(define speed-of-light 299792458.0)

(define (axis-index axis)
  (case axis [(x) 0] [(y) 1] [(z) 2]
    [else (raise-argument-error 'axis-index "(or/c 'x 'y 'z)" axis)]))

(define (flow-rgb electric-energy magnetic-energy)
  (define total (+ electric-energy magnetic-energy))
  (define electric-fraction
    (if (> total 1e-30) (/ electric-energy total) 0.5))
  (define white '(0.96 0.96 0.90))
  (define electric '(0.15 0.90 1.00))
  (define magnetic '(1.00 0.55 0.10))
  (define (blend a b fraction)
    (for/list ([x (in-list a)] [y (in-list b)])
      (+ x (* fraction (- y x)))))
  (if (< electric-fraction 0.5)
      (blend magnetic white (* 2 electric-fraction))
      (blend white electric (* 2 (- electric-fraction 0.5)))))

(define energy-legend-canvas%
  (class canvas%
    (super-new [min-width 220]
               [min-height 72]
               [stretchable-width #t]
               [stretchable-height #f]
               [style '(border)])
    (define/override (on-paint)
      (define dc (send this get-dc))
      (define-values (width _height) (send dc get-size))
      (send dc set-background (make-object color% 10 13 22))
      (send dc clear)
      (send dc set-text-foreground "white")
      (send dc draw-text "stored-energy character" 8 6)
      (define left 8)
      (define top 29)
      (define bar-width (max 1 (- width 16)))
      (for ([offset (in-range bar-width)])
        (define fraction (/ offset (max 1 (sub1 bar-width))))
        (define rgb
          (flow-rgb (* fraction 1.0) (- 1.0 fraction)))
        (send dc set-pen "transparent" 0 'transparent)
        (send dc set-brush
              (apply make-object color%
                     (map (lambda (channel) (exact-round (* 255 channel))) rgb))
              'solid)
        (send dc draw-rectangle (+ left offset) top 1 12))
      (send dc set-text-foreground (make-object color% 255 174 58))
      (send dc draw-text "magnetic" left 46)
      (send dc set-text-foreground (make-object color% 130 245 255))
      (define electric-label "electric")
      (define-values (label-width _label-height _descent _space)
        (send dc get-text-extent electric-label))
      (send dc draw-text electric-label (- width left label-width) 46))))

(define (show-near-field-poynting-particles
         result
         #:section [section-index 0]
         #:mode [initial-mode 'reactive]
         #:particles [particle-limit 12000]
         #:spawn-rate [initial-spawn-rate 1800.0]
         #:trail-length [trail-length 8]
         #:cycles-per-second [cycles-per-second 0.28]
         #:jitter [initial-jitter 0.0006]
         #:particle-size [initial-particle-size 1.0]
         #:antenna? [antenna? #t]
         #:width [width 1120]
         #:height [height 760])
  (define who 'show-near-field-poynting-particles)
  (unless (nec2c-near-field-result? result)
    (raise-argument-error who "nec2c-near-field-result?" result))
  (unless (and (exact-integer? section-index) (>= section-index 0)
               (< section-index
                  (length (nec2c-near-field-result-sections result))))
    (raise-arguments-error who "section index is outside the near-field result"
                           "section" section-index
                           "available sections"
                           (length (nec2c-near-field-result-sections result))))
  (unless (memq initial-mode '(reactive instantaneous average))
    (raise-argument-error who
                          "(or/c 'reactive 'instantaneous 'average)"
                          initial-mode))
  (unless (and (exact-integer? particle-limit) (positive? particle-limit))
    (raise-argument-error who "exact-positive-integer?" particle-limit))
  (unless (and (real? initial-spawn-rate) (positive? initial-spawn-rate))
    (raise-argument-error who "positive-real?" initial-spawn-rate))
  (unless (and (exact-integer? trail-length) (>= trail-length 2))
    (raise-argument-error who "(and/c exact-integer? (>=/c 2))" trail-length))
  (unless (and (real? cycles-per-second) (positive? cycles-per-second))
    (raise-argument-error who "positive-real?" cycles-per-second))
  (unless (and (real? initial-jitter) (>= initial-jitter 0) (<= initial-jitter 0.003))
    (raise-argument-error who "(real-in 0 0.003)" initial-jitter))
  (unless (and (real? initial-particle-size) (positive? initial-particle-size))
    (raise-argument-error who "positive-real?" initial-particle-size))
  (unless (and (exact-integer? width) (positive? width))
    (raise-argument-error who "exact-positive-integer?" width))
  (unless (and (exact-integer? height) (positive? height))
    (raise-argument-error who "exact-positive-integer?" height))

  (define current-result result)
  (define current-section-index section-index)
  (define current-section #f)
  (define flow-field #f)
  (define u-values #f)
  (define v-values #f)
  (define u-min 0.0)
  (define u-max 1.0)
  (define v-min 0.0)
  (define v-max 1.0)
  (define scene-radius 1.0)
  (define view-center origin)
  (define flow-origin-u 0.0)
  (define flow-origin-v 0.0)
  (define seed-weights '())
  (define seed-total 0.0)
  (define particles '())
  (define phase-degrees 0.0)
  (define mode initial-mode)
  (define playing? #t)
  (define spawn-rate (exact->inexact initial-spawn-rate))
  (define jitter-strength (exact->inexact initial-jitter))
  (define particle-size-scale (exact->inexact initial-particle-size))
  (define tone-map-exposure 1.5)
  (define spawn-accumulator 0.0)
  (define timer-period-ms 60)
  (define timer #f)
  (define phase-render-timer #f)
  (define phase-slider #f)
  (define phase-message #f)
  (define population-message #f)
  (define mode-choice #f)
  (define play-button #f)
  (define canvas #f)
  (define export-button #f)
  (define export-cycles-field #f)
  (define export-degrees-field #f)
  (define export-message #f)
  (define exporting? #f)
  (define packed-particle-data (make-f32vector 0))
  (define packed-trail-count 0)
  (define packed-outer-count 0)
  (define packed-core-count 0)

  (define (section-point u v [normal-offset 0.0])
    (apply pos (near-field-plane-point current-section u v normal-offset)))

  (define (edge-point edge location)
    (define start (vertex-point (wire-edge-start edge)))
    (define end (vertex-point (wire-edge-end edge)))
    (case location
      [(start) start]
      [(end) end]
      [else
       (point3 (/ (+ (point3-x start) (point3-x end)) 2.0)
               (/ (+ (point3-y start) (point3-y end)) 2.0)
               (/ (+ (point3-z start) (point3-z end)) 2.0))]))

  (define (point3-axis-coordinate point axis)
    (case axis
      [(x) (point3-x point)]
      [(y) (point3-y point)]
      [(z) (point3-z point)]))

  (define (weighted-index)
    (cond
      [(or (null? seed-weights) (<= seed-total 0))
       (random (* (vector-length u-values) (vector-length v-values)))]
      [else
       (define target (* (random) seed-total))
       (let loop ([weights seed-weights] [index 0] [total 0.0])
         (cond
           [(null? weights) (max 0 (sub1 index))]
           [(>= (+ total (car weights)) target) index]
           [else (loop (cdr weights) (add1 index) (+ total (car weights)))]))]))

  (define (seed-particle!)
    (define index (weighted-index))
    (define u-index (modulo index (vector-length u-values)))
    (define v-index (quotient index (vector-length u-values)))
    (define u (vector-ref u-values u-index))
    (define v (vector-ref v-values v-index))
    (define u-step
      (if (= u-index (sub1 (vector-length u-values)))
          (- u (vector-ref u-values (sub1 u-index)))
          (- (vector-ref u-values (add1 u-index)) u)))
    (define v-step
      (if (= v-index (sub1 (vector-length v-values)))
          (- v (vector-ref v-values (sub1 v-index)))
          (- (vector-ref v-values (add1 v-index)) v)))
    (define seeded-u
      (max u-min (min u-max (+ u (* (- (random) 0.5) u-step 0.7)))))
    (define seeded-v
      (max v-min (min v-max (+ v (* (- (random) 0.5) v-step 0.7)))))
    (flow-particle seeded-u seeded-v
                   (list (flow-trail-point seeded-u seeded-v
                                           '(0.96 0.96 0.90)))
                   0 '(0.96 0.96 0.90) '(0.96 0.96 0.90)))

  (define (reset-particles!)
    (set! particles '())
    (set! spawn-accumulator 0.0)
    (set! packed-particle-data (make-f32vector 0))
    (set! packed-trail-count 0)
    (set! packed-outer-count 0)
    (set! packed-core-count 0))

  (define (emit-particles! phase-step-degrees)
    ;; Emission is specified per second of the normal live animation. Scale
    ;; export-time emission by RF phase elapsed so additional temporal samples
    ;; do not inject additional probes into the same portion of a cycle.
    (define live-step
      (* 360 cycles-per-second (/ timer-period-ms 1000.0)))
    (set! spawn-accumulator
          (+ spawn-accumulator
             (* spawn-rate
                (/ timer-period-ms 1000.0)
                (/ phase-step-degrees live-step))))
    (define available (max 0 (- particle-limit (length particles))))
    ;; A ceiling drops emissions; it must not build a hidden backlog that
    ;; instantly replaces the next batch of escapees.
    (define scheduled-count
      (inexact->exact (floor spawn-accumulator)))
    (define emit-count
      (min available scheduled-count))
    (set! spawn-accumulator (- spawn-accumulator scheduled-count))
    (when (positive? emit-count)
      (set! particles
            (append particles
                    (for/list ([_ (in-range emit-count)])
                      (seed-particle!))))))

  (define (prepare-result! new-result)
    (unless (nec2c-near-field-result? new-result)
      (raise-argument-error 'visualization-update!
                            "nec2c-near-field-result?" new-result))
    (when (>= current-section-index
              (length (nec2c-near-field-result-sections new-result)))
      (raise-arguments-error 'visualization-update!
                             "updated result does not contain the selected section"
                             "section" current-section-index))
    (set! current-result new-result)
    (set! current-section
          (list-ref (nec2c-near-field-result-sections new-result)
                    current-section-index))
    (set! flow-field
          (make-near-field-flow-field
           current-section (nec2c-near-field-result-frequency-mhz new-result)))
    (set! u-values (near-field-flow-field-u-values flow-field))
    (set! v-values (near-field-flow-field-v-values flow-field))
    (set! u-min (vector-ref u-values 0))
    (set! u-max (vector-ref u-values (sub1 (vector-length u-values))))
    (set! v-min (vector-ref v-values 0))
    (set! v-max (vector-ref v-values (sub1 (vector-length v-values))))
    (set! scene-radius
          (max 1e-6 (* 0.55 (sqrt (+ (sqr (- u-max u-min))
                                      (sqr (- v-max v-min)))))))
    (set! view-center
          (section-point (/ (+ u-min u-max) 2.0)
                         (/ (+ v-min v-max) 2.0)))
    (define feed-edge
      (for/first ([edge (in-list (model-edges))]
                  #:when (wire-edge-feed? edge))
        edge))
    (define flow-origin-point
      (and feed-edge
           (edge-point feed-edge (wire-edge-feed-location feed-edge))))
    (set! flow-origin-u
          (if flow-origin-point
              (point3-axis-coordinate
               flow-origin-point
               (nec2c-near-field-section-u-axis current-section))
              (/ (+ u-min u-max) 2.0)))
    (set! flow-origin-v
          (if flow-origin-point
              (point3-axis-coordinate
               flow-origin-point
               (nec2c-near-field-section-v-axis current-section))
              (/ (+ v-min v-max) 2.0)))
    (set! seed-weights (near-field-flow-seed-weights flow-field))
    ;; A square-root weighting concentrates probes near stored energy without
    ;; collapsing the entire population into the strongest singular cell.
    (define maximum-weight (max 1e-30 (apply max seed-weights)))
    (set! seed-weights
          (map (lambda (weight) (+ 0.015 (sqrt (/ weight maximum-weight))))
               seed-weights))
    (set! seed-total (apply + seed-weights))
    (reset-particles!))

  (prepare-result! result)

  (define (particle-state particle)
    (near-field-flow-sample flow-field
                            (flow-particle-u particle)
                            (flow-particle-v particle)
                            (degrees->radians phase-degrees)
                            mode))

  (define (direction-rgb-at state u v)
    (cond
      [(not state) '(0.9 0.9 0.9)]
      [else
       (define velocity (near-field-flow-state-velocity state))
       (define du
         (list-ref velocity
                   (axis-index
                    (nec2c-near-field-section-u-axis current-section))))
       (define dv
         (list-ref velocity
                   (axis-index
                    (nec2c-near-field-section-v-axis current-section))))
       (define ru (- u flow-origin-u))
       (define rv (- v flow-origin-v))
       (define denominator
         (* (sqrt (+ (sqr du) (sqr dv)))
            (sqrt (+ (sqr ru) (sqr rv)))))
       (define radial-score
         (if (> denominator 1e-18)
             (max -1.0 (min 1.0 (/ (+ (* du ru) (* dv rv)) denominator)))
             0.0))
       (define neutral '(0.96 0.96 0.90))
       (define inward '(1.00 0.46 0.08))
       (define outward '(0.08 0.86 1.00))
       (define endpoint (if (negative? radial-score) inward outward))
       (for/list ([a (in-list neutral)] [b (in-list endpoint)])
         (+ a (* (abs radial-score) (- b a))))]))

  (define (energy-rgb-at state)
    (if state
        (flow-rgb (near-field-flow-state-electric-energy state)
                  (near-field-flow-state-magnetic-energy state))
        '(0.96 0.96 0.90)))

  (define (refresh-particle-colors!)
    (for ([particle (in-list particles)])
      (define state (particle-state particle))
      (set-flow-particle-direction-rgb!
       particle
       (direction-rgb-at state
                         (flow-particle-u particle)
                         (flow-particle-v particle)))
      (set-flow-particle-energy-rgb! particle (energy-rgb-at state))))

  (define (advance-particle! particle phase-step-degrees)
    (define state (particle-state particle))
    (cond
      [(not state) #f]
      [else
       (define velocity (near-field-flow-state-velocity state))
       (define u-component
         (list-ref velocity
                   (axis-index (nec2c-near-field-section-u-axis current-section))))
       (define v-component
         (list-ref velocity
                   (axis-index (nec2c-near-field-section-v-axis current-section))))
       (define speed (sqrt (+ (sqr u-component) (sqr v-component))))
       (define clamp-factor (if (> speed speed-of-light)
                                (/ speed-of-light speed) 1.0))
       (define seconds
         (/ (degrees->radians phase-step-degrees)
            (* 2 pi (nec2c-near-field-result-frequency-mhz current-result) 1e6)))
       ;; A deliberately tiny visual diffusion lets probes escape exact
       ;; numerical stagnation lines and nodes. It is not part of the field
       ;; solution and is bounded as a fraction of the displayed field span.
       ;; Jitter is a visual random walk. Scale each displacement by the square
       ;; root of elapsed phase so its variance per RF cycle remains constant
       ;; when the exporter uses smaller phase steps than live playback.
       (define jitter-step-scale
         (sqrt (/ (abs phase-step-degrees) phase-step)))
       (define jitter-distance
         (* scene-radius jitter-strength jitter-step-scale))
       (define next-u (+ (flow-particle-u particle)
                         (* u-component clamp-factor seconds)
                         (* jitter-distance (- (* 2.0 (random)) 1.0))))
       (define next-v (+ (flow-particle-v particle)
                         (* v-component clamp-factor seconds)
                         (* jitter-distance (- (* 2.0 (random)) 1.0))))
       (define old-trail (flow-particle-trail particle))
       (define reversed?
         (and (pair? (rest old-trail))
              (let* ([previous (second old-trail)]
                     [previous-u
                      (- (flow-particle-u particle)
                         (flow-trail-point-u previous))]
                     [previous-v
                      (- (flow-particle-v particle)
                         (flow-trail-point-v previous))])
                (< (+ (* previous-u u-component)
                      (* previous-v v-component))
                   0))))
       (define current-direction-rgb
         (direction-rgb-at state
                           (flow-particle-u particle)
                           (flow-particle-v particle)))
       (set-flow-particle-direction-rgb! particle current-direction-rgb)
       (set-flow-particle-energy-rgb! particle (energy-rgb-at state))
       (define trail-before-step
         (if reversed?
             (list (flow-trail-point (flow-particle-u particle)
                                     (flow-particle-v particle)
                                     current-direction-rgb))
             old-trail))
       (set-flow-particle-u! particle next-u)
       (set-flow-particle-v! particle next-v)
       ;; Age is measured in equivalent live-animation frames, keeping the
       ;; residence limit independent of export sampling resolution.
       (set-flow-particle-age!
        particle
        (+ (flow-particle-age particle)
           (/ (abs phase-step-degrees) phase-step)))
       (set-flow-particle-trail!
        particle
        (take (cons (flow-trail-point next-u next-v current-direction-rgb)
                    trail-before-step)
              (min trail-length (add1 (length trail-before-step)))))
       (if (or (< next-u u-min) (> next-u u-max)
               (< next-v v-min) (> next-v v-max)
               (> (flow-particle-age particle) 900))
           #f
           particle)]))

  ;; Pack every tracer bead into one interleaved GPU buffer. Pict3D spheres
  ;; made the original 1,200-particle experiment easy to prototype, but each
  ;; moving bead became a separate scene object. This representation reduces
  ;; a 12,000-particle frame to one upload and three point draws (trail, outer
  ;; head, energy core). Translucent additive blending makes dense streams
  ;; gather into a continuous, luminous fluid instead of opaque ball bearings.
  (define (particle-point-data)
    (define particle-count (length particles))
    (define trail-count
      (for/sum ([particle (in-list particles)])
        (max 0 (sub1 (length (flow-particle-trail particle))))))
    (define outer-count particle-count)
    (define core-count particle-count)
    (define packed
      (make-f32vector (* 7 (+ trail-count outer-count core-count)) 0.0))
    (define cursor 0)
    (define (put! value)
      (f32vector-set! packed cursor (exact->inexact value))
      (set! cursor (add1 cursor)))
    (define (push! coordinates rgb alpha)
      (put! (first coordinates))
      (put! (second coordinates))
      (put! (third coordinates))
      (put! (first rgb))
      (put! (second rgb))
      (put! (third rgb))
      (put! alpha))
    ;; Draw groups are contiguous so they can have different point sizes.
    (for ([particle (in-list particles)])
      (define points (flow-particle-trail particle))
      (for ([point (in-list (rest points))]
            [index (in-naturals 1)])
        (define fade (- 1.0 (/ index (max 1 trail-length))))
        (push! (near-field-plane-point
                current-section
                (flow-trail-point-u point)
                (flow-trail-point-v point))
               (flow-trail-point-direction-rgb point)
               (* 0.11 fade))))
    (define head-records
      (for/list ([particle (in-list particles)])
        (define coordinates
          (near-field-plane-point current-section
                                  (flow-particle-u particle)
                                  (flow-particle-v particle)))
        (push! coordinates (flow-particle-direction-rgb particle) 0.30)
        (cons coordinates (flow-particle-energy-rgb particle))))
    (for ([record (in-list head-records)])
      (push! (car record) (cdr record) 0.46))
    (values packed trail-count outer-count core-count))

  (define (update-packed-particle-data!)
    (define-values (data trail-count outer-count core-count)
      (particle-point-data))
    (set! packed-particle-data data)
    (set! packed-trail-count trail-count)
    (set! packed-outer-count outer-count)
    (set! packed-core-count core-count))

  (define (world-center-list)
    (list (pos-x view-center) (pos-y view-center) (pos-z view-center)))

  (define flow-particle-canvas%
    (class canvas%
      (init-field orientation-canvas status-label)
      (inherit with-gl-context swap-gl-buffers refresh get-gl-client-size)
      (define azimuth -42.0)
      (define altitude 24.0)
      (define zoom 3.1)
      (define dragging? #f)
      (define previous-x 0)
      (define previous-y 0)
      (define initialized? #f)
      (define particle-buffer 0)
      (define accumulation-framebuffer 0)
      (define accumulation-texture 0)
      (define accumulation-width 0)
      (define accumulation-height 0)
      (define tone-map-program 0)
      (define tone-map-texture-location -1)
      (define tone-map-exposure-location -1)
      (define float-size (gl-type-sizeof GL_FLOAT))
      (define record-size (* 7 float-size))
      (super-new [style '(gl no-autoclear)])

      (define/private (update-status!)
        (send orientation-canvas set-orientation azimuth altitude)
        (send status-label set-label
              (format "drag to orbit  |  wheel to zoom  |  azimuth ~a°  elevation ~a°"
                      (exact-round azimuth) (exact-round altitude))))

      (define/private (setup-gl!)
        (set! particle-buffer (u32vector-ref (glGenBuffers 1) 0))
        (set! accumulation-framebuffer
              (u32vector-ref (glGenFramebuffers 1) 0))
        (set! accumulation-texture (u32vector-ref (glGenTextures 1) 0))
        (define vertex-shader
          (load-shader
           (open-input-string
            (string-append
             "#version 120\n"
             "varying vec2 textureCoordinate;\n"
             "void main() {\n"
             "  gl_Position = gl_Vertex;\n"
             "  textureCoordinate = gl_MultiTexCoord0.xy;\n"
             "}\n"))
           GL_VERTEX_SHADER))
        (define fragment-shader
          (load-shader
           (open-input-string
            (string-append
             "#version 120\n"
             "uniform sampler2D accumulation;\n"
             "uniform float exposure;\n"
             "varying vec2 textureCoordinate;\n"
             "void main() {\n"
             "  vec3 hdr = texture2D(accumulation, textureCoordinate).rgb * exposure;\n"
             "  vec3 mapped = hdr / (vec3(1.0) + hdr);\n"
             "  float opacity = max(mapped.r, max(mapped.g, mapped.b));\n"
             "  gl_FragColor = vec4(mapped, opacity);\n"
             "}\n"))
           GL_FRAGMENT_SHADER))
        (set! tone-map-program (create-program vertex-shader fragment-shader))
        (glDeleteShader vertex-shader)
        (glDeleteShader fragment-shader)
        (set! tone-map-texture-location
              (glGetUniformLocation tone-map-program "accumulation"))
        (set! tone-map-exposure-location
              (glGetUniformLocation tone-map-program "exposure"))
        (glEnable GL_DEPTH_TEST)
        (glDepthFunc GL_LEQUAL)
        (glEnable GL_BLEND)
        (glEnable GL_POINT_SMOOTH)
        (glHint GL_POINT_SMOOTH_HINT GL_NICEST)
        (set! initialized? #t))

      (define/private (ensure-accumulation-target! width height)
        (unless (and (= width accumulation-width)
                     (= height accumulation-height))
          (set! accumulation-width width)
          (set! accumulation-height height)
          (define previous-framebuffer
            (s32vector-ref (glGetIntegerv GL_FRAMEBUFFER_BINDING) 0))
          (glBindTexture GL_TEXTURE_2D accumulation-texture)
          (glTexParameteri GL_TEXTURE_2D GL_TEXTURE_MIN_FILTER GL_LINEAR)
          (glTexParameteri GL_TEXTURE_2D GL_TEXTURE_MAG_FILTER GL_LINEAR)
          (glTexParameteri GL_TEXTURE_2D GL_TEXTURE_WRAP_S GL_CLAMP_TO_EDGE)
          (glTexParameteri GL_TEXTURE_2D GL_TEXTURE_WRAP_T GL_CLAMP_TO_EDGE)
          (glTexImage2D GL_TEXTURE_2D 0 GL_RGBA16F
                        width height 0 GL_RGBA GL_FLOAT 0)
          (glBindFramebuffer GL_FRAMEBUFFER accumulation-framebuffer)
          (glFramebufferTexture2D GL_FRAMEBUFFER GL_COLOR_ATTACHMENT0
                                  GL_TEXTURE_2D accumulation-texture 0)
          (glDrawBuffer GL_COLOR_ATTACHMENT0)
          (glReadBuffer GL_COLOR_ATTACHMENT0)
          (unless (= (glCheckFramebufferStatus GL_FRAMEBUFFER)
                     GL_FRAMEBUFFER_COMPLETE)
            (error 'show-near-field-poynting-particles
                   "unable to create floating-point particle accumulation buffer"))
          (glBindTexture GL_TEXTURE_2D 0)
          (glBindFramebuffer GL_FRAMEBUFFER previous-framebuffer)))

      (define/private (set-projection! width height)
        (define safe-height (max 1 height))
        (define aspect (/ (exact->inexact (max 1 width)) safe-height))
        (define near 0.05)
        (define far 80.0)
        (define half-height (* near (tan (degrees->radians 16.0))))
        (define half-width (* half-height aspect))
        (glViewport 0 0 (max 1 width) safe-height)
        (glMatrixMode GL_PROJECTION)
        (glLoadIdentity)
        (glFrustum (- half-width) half-width
                   (- half-height) half-height near far)
        (glMatrixMode GL_MODELVIEW))

      (define/private (vertex point)
        (glVertex3d (point3-x point) (point3-y point) (point3-z point)))

      (define/private (draw-static!)
        (glBlendFunc GL_SRC_ALPHA GL_ONE_MINUS_SRC_ALPHA)
        (glLineWidth 1.0)
        (glColor4d 0.10 0.48 0.62 0.34)
        (glBegin GL_LINES)
        (for ([fraction (in-range 0 1.001 0.1)])
          (define u (+ u-min (* fraction (- u-max u-min))))
          (apply glVertex3d (near-field-plane-point current-section u v-min))
          (apply glVertex3d (near-field-plane-point current-section u v-max)))
        (for ([fraction (in-range 0 1.001 0.1)])
          (define v (+ v-min (* fraction (- v-max v-min))))
          (apply glVertex3d (near-field-plane-point current-section u-min v))
          (apply glVertex3d (near-field-plane-point current-section u-max v)))
        (glEnd)
        (when antenna?
          (glLineWidth 7.0)
          (glColor4d 0.02 0.18 0.24 0.95)
          (glBegin GL_LINES)
          (for ([edge (in-list (model-edges))])
            (vertex (edge-point edge 'start))
            (vertex (edge-point edge 'end)))
          (glEnd)
          (glLineWidth 3.0)
          (glColor4d 0.35 0.92 1.0 1.0)
          (glBegin GL_LINES)
          (for ([edge (in-list (model-edges))])
            (vertex (edge-point edge 'start))
            (vertex (edge-point edge 'end)))
          (glEnd)
          (glPointSize 13.0)
          (glColor4d 1.0 0.02 0.52 1.0)
          (glBegin GL_POINTS)
          (for ([edge (in-list (model-edges))]
                #:when (wire-edge-feed? edge))
            (vertex (edge-point edge (wire-edge-feed-location edge))))
          (glEnd)))

      (define/private (draw-particles!)
        (define total-count
          (+ packed-trail-count packed-outer-count packed-core-count))
        (when (positive? total-count)
          (glBindBuffer GL_ARRAY_BUFFER particle-buffer)
          (glBufferData GL_ARRAY_BUFFER
                        (gl-vector-sizeof packed-particle-data)
                        packed-particle-data GL_STREAM_DRAW)
          (glVertexPointer 3 GL_FLOAT record-size 0)
          (glColorPointer 4 GL_FLOAT record-size (* 3 float-size))
          (glEnableClientState GL_VERTEX_ARRAY)
          (glEnableClientState GL_COLOR_ARRAY)
          ;; Additive alpha is intentionally used here: one probe remains
          ;; delicate, while coincident probes build opacity and brightness.
          (glBlendFunc GL_SRC_ALPHA GL_ONE)
          (glDepthMask #f)
          (glPointSize (* 2.4 particle-size-scale))
          (glDrawArrays GL_POINTS 0 packed-trail-count)
          (glPointSize (* 5.4 particle-size-scale))
          (glDrawArrays GL_POINTS packed-trail-count packed-outer-count)
          (glPointSize (* 2.8 particle-size-scale))
          (glDrawArrays GL_POINTS
                        (+ packed-trail-count packed-outer-count)
                        packed-core-count)
          (glDepthMask #t)
          (glDisableClientState GL_COLOR_ARRAY)
          (glDisableClientState GL_VERTEX_ARRAY)
          (glBindBuffer GL_ARRAY_BUFFER 0)))

      (define/private (composite-particles! width height)
        (glDisable GL_DEPTH_TEST)
        ;; The tone-mapped RGB is premultiplied by an opacity equal to its
        ;; brightest channel. This keeps the static model visible beneath dim
        ;; flow while allowing dense flow to become opaque without clipping.
        (glBlendFunc GL_ONE GL_ONE_MINUS_SRC_ALPHA)
        (glMatrixMode GL_PROJECTION)
        (glPushMatrix)
        (glLoadIdentity)
        (glMatrixMode GL_MODELVIEW)
        (glPushMatrix)
        (glLoadIdentity)
        (glUseProgram tone-map-program)
        (glActiveTexture GL_TEXTURE0)
        (glBindTexture GL_TEXTURE_2D accumulation-texture)
        (glUniform1i tone-map-texture-location 0)
        (glUniform1f tone-map-exposure-location tone-map-exposure)
        (glColor4d 1.0 1.0 1.0 1.0)
        (glBegin GL_QUADS)
        (glTexCoord2d 0.0 0.0) (glVertex2d -1.0 -1.0)
        (glTexCoord2d 1.0 0.0) (glVertex2d  1.0 -1.0)
        (glTexCoord2d 1.0 1.0) (glVertex2d  1.0  1.0)
        (glTexCoord2d 0.0 1.0) (glVertex2d -1.0  1.0)
        (glEnd)
        (glBindTexture GL_TEXTURE_2D 0)
        (glUseProgram 0)
        (glPopMatrix)
        (glMatrixMode GL_PROJECTION)
        (glPopMatrix)
        (glMatrixMode GL_MODELVIEW)
        (glEnable GL_DEPTH_TEST))

      (define/override (on-size width height)
        (when (and (positive? width) (positive? height))
          (with-gl-context (lambda () (set-projection! width height)))))

      (define/private (draw-current-frame!)
        (unless initialized? (setup-gl!))
        (define-values (width height) (get-gl-client-size))
        (ensure-accumulation-target! width height)
        (define display-framebuffer
          (s32vector-ref (glGetIntegerv GL_FRAMEBUFFER_BINDING) 0))

        ;; First retain unclamped additive particle light in an RGBA16F target.
        ;; This is what gives the later display pass enough dynamic range to
        ;; preserve both isolated flow and dense near-conductor accumulation.
        (glBindFramebuffer GL_FRAMEBUFFER accumulation-framebuffer)
        (set-projection! width height)
        (glClearColor 0.0 0.0 0.0 0.0)
        (glClear GL_COLOR_BUFFER_BIT)
        (glMatrixMode GL_MODELVIEW)
        (glLoadIdentity)
        (glTranslated 0.0 0.0 (- zoom))
        (glRotated altitude 1.0 0.0 0.0)
        (glRotated azimuth 0.0 0.0 1.0)
        (glScaled (/ scene-radius) (/ scene-radius) (/ scene-radius))
        (define center (world-center-list))
        (glTranslated (- (first center)) (- (second center)) (- (third center)))
        (glDisable GL_DEPTH_TEST)
        (draw-particles!)

        ;; Draw ordinary geometry to the window, then apply the compressive
        ;; fullscreen particle pass over it.
        (glBindFramebuffer GL_FRAMEBUFFER display-framebuffer)
        (set-projection! width height)
        (glClearColor 0.0 0.0 0.0 1.0)
        (glClear (bitwise-ior GL_COLOR_BUFFER_BIT GL_DEPTH_BUFFER_BIT))
        (glEnable GL_DEPTH_TEST)
        (glMatrixMode GL_MODELVIEW)
        (glLoadIdentity)
        (glTranslated 0.0 0.0 (- zoom))
        (glRotated altitude 1.0 0.0 0.0)
        (glRotated azimuth 0.0 0.0 1.0)
        (glScaled (/ scene-radius) (/ scene-radius) (/ scene-radius))
        (glTranslated (- (first center)) (- (second center)) (- (third center)))
        (draw-static!)
        (composite-particles! width height)
        (glFlush))

      (define/override (on-paint)
        (with-gl-context (lambda () (draw-current-frame!)))
        (swap-gl-buffers))

      (define/public (capture-rgba)
        (with-gl-context
         (lambda ()
           (draw-current-frame!)
           (define-values (width height) (get-gl-client-size))
           (define pixels (make-u8vector (* width height 4)))
           (glPixelStorei GL_PACK_ALIGNMENT 1)
           (glReadBuffer GL_BACK)
           (glFinish)
           (glReadPixels 0 0 width height GL_RGBA GL_UNSIGNED_BYTE
                         (u8vector->cpointer pixels))
           (values width height pixels))))

      (define/override (on-event event)
        (define type (send event get-event-type))
        (define x (send event get-x))
        (define y (send event get-y))
        (case type
          [(left-down)
           (set! dragging? #t)
           (set! previous-x x)
           (set! previous-y y)]
          [(left-up) (set! dragging? #f)]
          [(motion)
           (when dragging?
             (set! azimuth (- azimuth (* 0.45 (- x previous-x))))
             (set! altitude
                   (max -89.0 (min 89.0
                                    (+ altitude (* 0.45 (- y previous-y))))))
             (set! previous-x x)
             (set! previous-y y)
             (update-status!)
             (refresh))]
          [(wheel-up)
           (set! zoom (max 1.25 (* zoom 0.88)))
           (refresh)]
          [(wheel-down)
           (set! zoom (min 20.0 (/ zoom 0.88)))
           (refresh)]
          [else (void)]))

      (define/override (on-char event)
        (case (send event get-key-code)
          [(wheel-up #\+)
           (set! zoom (max 1.25 (* zoom 0.88)))
           (refresh)]
          [(wheel-down #\-)
           (set! zoom (min 20.0 (/ zoom 0.88)))
           (refresh)]
          [else (void)]))

      (define/public (refresh-scene) (refresh))
      (update-status!)))

  (define frame
    (new frame%
         [label "NEC2C reactive near-field energy flow — experimental"]
         [width width]
         [height height]))
  (define eventspace (current-eventspace))
  (define root (new vertical-panel% [parent frame]))
  (define body (new horizontal-panel% [parent root]))
  (define controls
    (new vertical-panel% [parent body] [min-width 250]
         [stretchable-width #f] [alignment '(left top)]))
  (new message% [parent controls]
       [label "POYNTING PARTICLE LAB"]
       [font (make-object font% 13 'default 'normal 'bold)])
  (new message% [parent controls]
       [label (string-append
               "Motion: S/u energy velocity\n"
               "Outer/trail: amber inward · cyan outward\n"
               "Inner core: magnetic ← pale → electric")])
  (set! population-message
        (new message%
             [parent controls]
             [label (format "0 active · ~a/s emission · ~a ceiling"
                            (real->decimal-string spawn-rate 1)
                            particle-limit)]
             [min-width 245]))
  (set! mode-choice
        (new choice%
             [parent controls]
             [label "FLOW"]
             [choices '("reactive (instantaneous − average)"
                        "instantaneous" "time average")]
             [selection (case mode [(reactive) 0] [(instantaneous) 1] [else 2])]
             [callback
              (lambda (choice _event)
                (set! mode (list-ref '(reactive instantaneous average)
                                     (send choice get-selection)))
                (reset-particles!)
                (render-frame! #f))]))
  (set! play-button
        (new button%
             [parent controls]
             [label "PAUSE"]
             [callback
              (lambda (button _event)
                (set! playing? (not playing?))
                (send button set-label (if playing? "PAUSE" "PLAY")))]))
  (set! phase-message
        (new message% [parent controls] [label "phase 0°"] [min-width 170]))
  (set! phase-slider
        (new slider%
             [parent controls]
             [label "PHASE"]
             [min-value 0] [max-value 359] [init-value 0]
             [style '(horizontal plain)]
             [callback
              (lambda (slider _event)
                (set! phase-degrees (send slider get-value))
                (set! playing? #f)
                (send play-button set-label "PLAY")
                ;; Resampling thousands of field probes synchronously for
                ;; every mouse-motion event makes the native slider fight the
                ;; pointer. Coalesce a drag into one render after it rests.
                (when phase-render-timer
                  (send phase-render-timer stop)
                  (send phase-render-timer start 160 #t)))]))
  (new slider%
       [parent controls]
       [label "SPAWN / SECOND"]
       [min-value 1] [max-value 6000]
       [init-value (max 1 (min 6000 (exact-round spawn-rate)))]
       [style '(horizontal plain)]
       [callback
        (lambda (slider _event)
          (set! spawn-rate (exact->inexact (send slider get-value))))])
  (new slider%
       [parent controls]
       [label "MICRO-JITTER"]
       [min-value 0] [max-value 100]
       [init-value
        (max 0 (min 100
                    (exact-round (* 100.0 (/ jitter-strength 0.003)))))]
       [style '(horizontal plain)]
       [callback
        (lambda (slider _event)
          (set! jitter-strength
                (* 0.003 (/ (send slider get-value) 100.0))))])
  (new slider%
       [parent controls]
       [label "PARTICLE SIZE"]
       [min-value 25] [max-value 250]
       [init-value
        (max 25 (min 250 (exact-round (* 100.0 particle-size-scale))))]
       [style '(horizontal plain)]
       [callback
        (lambda (slider _event)
          (set! particle-size-scale
                (/ (send slider get-value) 100.0))
          (send canvas refresh-scene))])
  (new slider%
       [parent controls]
       [label "EXPOSURE ×1.50"]
       [min-value 10] [max-value 500] [init-value 150]
       [style '(horizontal plain)]
       [callback
        (lambda (slider _event)
          (set! tone-map-exposure (/ (send slider get-value) 100.0))
          (send slider set-label
                (format "EXPOSURE ×~a"
                        (real->decimal-string tone-map-exposure 2)))
          (send canvas refresh-scene))])
  (set! export-cycles-field
        (new text-field% [parent controls]
             [label "VIDEO CYCLES"] [init-value "3"]
             [min-width 245] [stretchable-width #f]))
  (set! export-degrees-field
        (new text-field% [parent controls]
             [label "DEGREES / FRAME"] [init-value "1"]
             [min-width 245] [stretchable-width #f]))
  (set! export-button
        (new button% [parent controls] [label "EXPORT MP4"]
             [callback (lambda (_button _event) (begin-video-export!))]))
  (set! export-message
        (new message% [parent controls] [label ""] [min-width 245]))
  (new button%
       [parent controls]
       [label "CLEAR / RESTART FLOW"]
       [callback
        (lambda (_button _event)
          (reset-particles!)
          (render-frame! #f))])
  (new energy-legend-canvas% [parent controls])
  (new message% [parent controls]
       [label (format "~a-sample trails · continuous emission\n~a MHz · section ~a"
                      trail-length
                      (real->decimal-string
                       (exact->inexact
                        (nec2c-near-field-result-frequency-mhz result)) 5)
                      section-index)])
  (define footer
    (new horizontal-panel% [parent root] [stretchable-height #f]
         [alignment '(left center)]))
  (define orientation-canvas (new orientation-canvas% [parent footer]))
  (define orbit-status
    (new message% [parent footer] [label "drag to orbit | wheel to zoom"]
         [stretchable-width #t]))
  (set! canvas
        (new flow-particle-canvas%
             [parent body]
             [orientation-canvas orientation-canvas]
             [status-label orbit-status]))

  ;; Simulation remains deliberately modest in cadence so phase reversal is
  ;; legible. Rendering is now a single packed GPU upload rather than a Pict3D
  ;; scene rebuild, so population no longer multiplies scene-object overhead.
  (define phase-step (* 360 cycles-per-second (/ timer-period-ms 1000.0)))
  (define (render-frame! [advance? #f]
                         [frame-phase-step phase-step]
                         [refresh-canvas? #t])
    (when advance?
      (define next-phase (+ phase-degrees frame-phase-step))
      (set! phase-degrees (- next-phase (* 360.0 (floor (/ next-phase 360.0)))))
      (set! particles
            (filter values
                    (for/list ([particle (in-list particles)])
                      (advance-particle! particle frame-phase-step))))
      (emit-particles! frame-phase-step))
    (unless advance?
      (refresh-particle-colors!))
    (update-packed-particle-data!)
    ;; exact-round legitimately reaches 360 in the last half-degree even
    ;; though the continuous phase has already been normalized below 360.
    ;; Wrap the presentation value independently to keep slider% in range.
    (define displayed-phase (modulo (exact-round phase-degrees) 360))
    (send phase-slider set-value displayed-phase)
    (send phase-message set-label
          (format "phase ~a° · ~a"
                  displayed-phase
                  (case mode
                    [(reactive) "reactive slosh"]
                    [(instantaneous) "instantaneous flow"]
                    [else "time-average flow"])))
    (send population-message set-label
          (format "~a active · ~a/s emission · ~a ceiling"
                  (length particles)
                  (real->decimal-string spawn-rate 1)
                  particle-limit))
    (when refresh-canvas?
      (send canvas refresh-scene)))

  (define (capture-export-frame [phase-increment #f])
    ;; OpenGL contexts and widget state belong to the GUI eventspace. The
    ;; encoder worker requests one frame at a time and waits without blocking
    ;; the event thread between frames.
    (define ready (make-semaphore 0))
    (define result-box (box #f))
    (define failure-box (box #f))
    (parameterize ([current-eventspace eventspace])
      (queue-callback
       (lambda ()
         (with-handlers ([exn:fail? (lambda (failure)
                                      (set-box! failure-box failure))])
           (if phase-increment
               (render-frame! #t phase-increment #f)
               (render-frame! #f phase-step #f))
           (set-box! result-box
                     (call-with-values
                      (lambda () (send canvas capture-rgba)) list)))
         (semaphore-post ready))
       #f))
    (semaphore-wait ready)
    (when (unbox failure-box) (raise (unbox failure-box)))
    (apply values (unbox result-box)))

  (define (set-export-status! label [enabled? #f])
    (parameterize ([current-eventspace eventspace])
      (queue-callback
       (lambda ()
         (send export-message set-label label)
         (send export-button enable enabled?)
         (when enabled?
           (set! exporting? #f)
           (send canvas refresh-scene)))
       #f)))

  (define (set-export-failure! detail)
    (parameterize ([current-eventspace eventspace])
      (queue-callback
       (lambda ()
         (set! exporting? #f)
         (send export-button enable #t)
         (send export-message set-label "Export failed — see error dialog")
         (send canvas refresh-scene)
         (message-box "MP4 Export Failed" detail frame '(ok stop)))
       #f)))

  (define (run-video-export! cycles-value degrees-per-frame destination ffmpeg)
    (set! exporting? #t)
    (send export-button enable #f)
    (define export-fps 30)
    (define frames-per-cycle
      (max 1 (inexact->exact (ceiling (/ 360.0 degrees-per-frame)))))
    (define frame-count (* cycles-value frames-per-cycle))
    (define export-phase-step (/ 360.0 frames-per-cycle))
    (send export-message set-label
          (format "Preparing ~a frames · ~a s…"
                  frame-count
                  (real->decimal-string
                   (/ (exact->inexact frame-count) export-fps) 1)))
    (thread
     (lambda ()
       (define encoder #f)
       (define encoder-out #f)
       (define encoder-in #f)
       (define encoder-error #f)
       (with-handlers
           ([exn:fail?
             (lambda (failure)
               (when (and (output-port? encoder-in)
                          (not (port-closed? encoder-in)))
                 (close-output-port encoder-in))
               (when (and encoder
                          (eq? (subprocess-status encoder) 'running))
                 (subprocess-kill encoder #t))
               (when (and (input-port? encoder-out)
                          (not (port-closed? encoder-out)))
                 (close-input-port encoder-out))
               (when (and (input-port? encoder-error)
                          (not (port-closed? encoder-error)))
                 (close-input-port encoder-error))
               (set-export-failure! (exn-message failure)))])
         (for ([frame-index (in-range frame-count)])
           (define-values (video-width video-height pixels)
             ;; Preserve the paused presentation as frame zero. Subsequent
             ;; frames advance one exact sample of the requested RF cycle.
             (if (zero? frame-index)
                 (capture-export-frame)
                 (capture-export-frame export-phase-step)))
           (unless encoder
             (define-values (process stdout stdin stderr)
               (subprocess
                ;; A GUI/REPL current-error-port is commonly a pipe or string
                ;; port, but subprocess only accepts a native file-stream port
                ;; for direct redirection. Request a child stderr pipe instead.
                #f #f #f ffmpeg
                "-hide_banner" "-loglevel" "error" "-y"
                "-f" "rawvideo" "-pixel_format" "rgba"
                "-video_size" (format "~ax~a" video-width video-height)
                "-framerate" (number->string export-fps)
                "-i" "-"
                "-vf" "vflip,scale=trunc(iw/2)*2:trunc(ih/2)*2"
                "-an" "-c:v" "libx264" "-preset" "medium"
                "-crf" "18" "-pix_fmt" "yuv420p"
                "-movflags" "+faststart"
                (path->string destination)))
             (set! encoder process)
             (set! encoder-out stdout)
             (set! encoder-in stdin)
             (set! encoder-error stderr))
           (write-bytes pixels encoder-in)
           (when (or (= frame-index (sub1 frame-count))
                     (zero? (modulo frame-index 15)))
             (set-export-status!
              (format "Exporting ~a% · frame ~a/~a"
                      (exact-round
                       (* 100.0 (/ (add1 frame-index) frame-count)))
                      (add1 frame-index) frame-count))))
         (close-output-port encoder-in)
         (subprocess-wait encoder)
         (when (input-port? encoder-out)
           (close-input-port encoder-out))
         (define exit-code (subprocess-status encoder))
         (define encoder-diagnostics
           (if (input-port? encoder-error)
               (let ([text (string-trim (port->string encoder-error))])
                 (close-input-port encoder-error)
                 text)
               ""))
         (if (zero? exit-code)
             ;; The chooser already showed the destination; keeping the
             ;; in-panel result compact avoids widening the control rail.
             (set-export-status! "MP4 export complete" #t)
             (error 'show-near-field-poynting-particles
                    "ffmpeg exited with status ~a~a"
                    exit-code
                    (if (string=? encoder-diagnostics "")
                        ""
                        (string-append "\n" encoder-diagnostics))))))))

  (define (begin-video-export!)
    (cond
      [exporting? (void)]
      [playing?
       (message-box "Export MP4"
                    "Pause the animation before exporting so the current view and phase are the starting state."
                    frame '(ok caution))]
      [else
       (define cycles-value
         (string->number (string-trim (send export-cycles-field get-value))))
       (define degrees-per-frame
         (string->number (string-trim (send export-degrees-field get-value))))
       (cond
         [(not (and cycles-value (exact-integer? cycles-value)
                    (<= 1 cycles-value 60)))
           (message-box "Export MP4"
                        "VIDEO CYCLES must be a whole number from 1 through 60."
                        frame '(ok caution))]
         [(not (and degrees-per-frame (real? degrees-per-frame)
                    (<= 0.1 degrees-per-frame 30.0)))
          (message-box "Export MP4"
                       "DEGREES / FRAME must be from 0.1 through 30."
                       frame '(ok caution))]
         [else
          (define destination
            (put-file "Export Poynting-flow MP4" frame #f
                      "poynting-flow.mp4" "mp4" '(common)
                      '(("MP4 video" "*.mp4"))))
          (when destination
            ;; ffmpeg is a documented runtime requirement for this
            ;; experimental exporter, just as nec2c is for NEC analyses.
            ;; Let subprocess report an actionable launch failure if the
            ;; host installation is broken rather than maintaining a
            ;; second, pre-flight availability path here.
            (run-video-export! cycles-value degrees-per-frame destination
                               (find-executable-path "ffmpeg")))])]))
  (set! phase-render-timer
        (new timer%
             [notify-callback (lambda () (render-frame! #f))]))
  (set! timer
        (new timer%
             [notify-callback
              (lambda ()
                (when (and (send frame is-shown?) playing?)
                  (render-frame! #t)))]))
  (send timer start timer-period-ms)
  (send frame show #t)
  (make-visualization-handle
   (lambda (new-result)
     (send timer stop)
     (send phase-render-timer stop)
     (prepare-result! new-result)
     (queue-in-eventspace
      eventspace
      (lambda ()
        (render-frame! #f)
        (when (send frame is-shown?)
          (send timer start timer-period-ms)))))
   (lambda () (send frame show #t) (send timer start timer-period-ms))
   (lambda ()
     (send timer stop)
     (send phase-render-timer stop)
     (send frame show #f))
   (lambda () (send frame is-shown?))))

;; A deliberately separate workbench for deciding how the production color
;; ramps should be distributed.  It edits only stop positions; the named
;; palettes and the ordinary viewer remain immutable while experiments are in
;; progress.
(define color-swatch%
  (class canvas%
    (init-field rgb)
    (super-new [min-width 30]
               [min-height 18]
               [stretchable-width #f]
               [stretchable-height #f]
               [style '(border)])
    (define/override (on-paint)
      (define dc (send this get-dc))
      (send dc set-pen "transparent" 0 'transparent)
      (send dc set-brush
            (apply make-object color% (map exact-round rgb)) 'solid)
      (define-values (width height) (send dc get-size))
      (send dc draw-rectangle 0 0 width height))))

(define palette-lab-palettes
  '(mmana magma sdr inferno viridis grayscale electric))

(define (show-radiation-palette-lab grid
                                    #:component [component 'total]
                                    #:floor-db [floor-db -40]
                                    #:normalize? [normalize? #t]
                                    #:scale [radial-scale 'arrl]
                                    #:palette [palette 'magma]
                                    #:mesh-step [mesh-step 2]
                                    #:axes? [axes? #t]
                                    #:antenna? [antenna? #t]
                                    #:spherical-grid? [spherical-grid? #f]
                                    #:width [width 1240]
                                    #:height [height 800])
  (unless (nec2c-pattern-grid? grid)
    (raise-argument-error 'show-radiation-palette-lab
                          "nec2c-pattern-grid?" grid))
  (unless (and (exact-integer? width) (positive? width))
    (raise-argument-error 'show-radiation-palette-lab
                          "exact-positive-integer?" width))
  (unless (and (exact-integer? height) (positive? height))
    (raise-argument-error 'show-radiation-palette-lab
                          "exact-positive-integer?" height))
  (unless (boolean? axes?)
    (raise-argument-error 'show-radiation-palette-lab "boolean?" axes?))
  (unless (boolean? antenna?)
    (raise-argument-error 'show-radiation-palette-lab "boolean?" antenna?))
  (unless (boolean? spherical-grid?)
    (raise-argument-error 'show-radiation-palette-lab
                          "boolean?" spherical-grid?))
  (validate-radial-scale 'show-radiation-palette-lab radial-scale)
  (resolve-palette 'show-radiation-palette-lab palette)
  (define current-grid grid)
  (define current-palette palette)
  (define current-stops
    (map (lambda (stop) (cons (car stop) (cdr stop)))
         (resolve-palette 'show-radiation-palette-lab palette)))
  (define show-grid? spherical-grid?)
  (define-values (surface radius view-center peak-gain)
    (build-radiation-pict3d
     current-grid
     #:component component
     #:floor-db floor-db
     #:normalize? normalize?
     #:scale radial-scale
     #:palette current-palette
     #:color-stops current-stops
     #:mesh-step mesh-step
     #:spherical-grid? show-grid?))
  (define frame
    (new frame%
         [label (format "~a radiation palette laboratory"
                        (radiation-backend-title grid))]
         [width width]
         [height height]))
  (define eventspace (current-eventspace))
  (define root (new vertical-panel% [parent frame]))
  (define body (new horizontal-panel% [parent root]))
  (define viewport (new vertical-panel% [parent body]))
  (define controls
    (new vertical-panel%
         [parent body]
         [min-width 350]
         [stretchable-width #f]
         [alignment '(left top)]))
  (define footer
    (new horizontal-panel%
         [parent root]
         [alignment '(left center)]
         [stretchable-height #f]))
  (define orientation-canvas
    (and axes? (new orientation-canvas% [parent footer])))
  (define antenna-canvas
    (and antenna?
         (new antenna-inset-canvas% [parent footer] [edges (model-edges)])))
  (define status
    (new message%
         [parent footer]
         [label "drag to orbit  |  wheel to zoom"]
         [stretchable-width #t]))
  (define canvas
    (parameterize ([current-pict3d-background (rgba "black")]
                   [current-pict3d-ambient (emitted "white" 1.0)]
                   [current-pict3d-fov view-fov-degrees])
      (new orbit-canvas%
           [parent viewport]
           [surface surface]
           [view-center view-center]
           [radius radius]
           [orientation-canvas orientation-canvas]
           [antenna-canvas antenna-canvas]
           [status-label status])))
  (send canvas set-async-updates? #t)
  (new message% [parent controls] [label "COLOR RAMP LAB"])
  (new message%
       [parent controls]
       [label "Move each interior tone to the dB level where it should appear."])
  (define palette-choice
    (new choice%
         [parent controls]
         [label "Named ramp"]
         [choices (map symbol->string palette-lab-palettes)]
         [selection (or (index-of palette-lab-palettes palette) 0)]
         [callback
          (lambda (choice _event)
            (set! current-palette
                  (list-ref palette-lab-palettes (send choice get-selection)))
            (set! current-stops
                  (map (lambda (stop) (cons (car stop) (cdr stop)))
                       (resolve-palette 'show-radiation-palette-lab
                                        current-palette)))
            (rebuild-stop-controls!)
            (schedule-render!))]))
  (define grid-check
    (new check-box%
         [parent controls]
         [label "Spherical coordinate grid"]
         [value show-grid?]
         [callback
          (lambda (check _event)
            (set! show-grid? (send check get-value))
            (schedule-render!))]))
  (define stops-panel
    (new group-box-panel%
         [parent controls]
         [label "Tone positions (dB relative)"]
         [alignment '(left top)]))
  (define legend
    (new legend-canvas%
         [parent controls]
         [radial-scale radial-scale]
         [palette current-palette]
         [color-stops current-stops]
         [peak-gain peak-gain]
         [color-step #f]))
  (define button-row
    (new horizontal-panel%
         [parent controls]
         [stretchable-height #f]
         [alignment '(center center)]))
  (new button%
       [parent button-row]
       [label "RESET RAMP"]
       [callback
        (lambda (_button _event)
          (set! current-stops
                (map (lambda (stop) (cons (car stop) (cdr stop)))
                     (resolve-palette 'show-radiation-palette-lab
                                      current-palette)))
          (rebuild-stop-controls!)
          (schedule-render!))])
  (new button%
       [parent button-row]
       [label "COPY STOPS"]
       [callback
        (lambda (_button _event)
          (send the-clipboard set-clipboard-string
                (format "'~s" current-stops) 0)
          (send status set-label "color-stop definition copied to clipboard"))])
  (define render-debounce-ms 500.0)
  (define render-generation 0)
  (define last-render-request-ms -inf.0)
  (define rebuild-timer
    (new timer%
         [notify-callback
          (lambda () (render-after-inactivity!))]))
  (define (schedule-render!)
    ;; Measure from the most recent event rather than merely delaying each
    ;; callback. This remains correct even if an already-queued timer callback
    ;; arrives while the user is still dragging.
    (set! render-generation (add1 render-generation))
    (set! last-render-request-ms (current-inexact-milliseconds))
    (send status set-label "palette changed — waiting to redraw…")
    (send rebuild-timer stop)
    (send rebuild-timer start (inexact->exact (ceiling render-debounce-ms)) #t))
  (define (render-after-inactivity!)
    (define remaining-ms
      (- render-debounce-ms
         (- (current-inexact-milliseconds) last-render-request-ms)))
    (if (positive? remaining-ms)
        (send rebuild-timer start
              (max 1 (inexact->exact (ceiling remaining-ms))) #t)
        (render-current! render-generation)))
  (define (render-current! generation)
    ;; Snapshot all mutable controls before leaving the eventspace. Pict3D
    ;; surface construction is expensive, so perform it in a worker and queue
    ;; only the inexpensive widget replacement back to the GUI thread.
    (define grid-snapshot current-grid)
    (define palette-snapshot current-palette)
    (define stops-snapshot
      (map (lambda (stop) (cons (car stop) (cdr stop))) current-stops))
    (define grid-visible-snapshot show-grid?)
    (send status set-label "rebuilding palette surface…")
    (thread
     (lambda ()
       (with-handlers
           ([exn:fail?
             (lambda (failure)
               (queue-in-eventspace
                eventspace
                (lambda ()
                  (when (= generation render-generation)
                    (send status set-label
                          (format "palette rebuild failed: ~a"
                                  (exn-message failure)))))))])
         (define-values (new-surface new-radius new-center new-peak)
           (build-radiation-pict3d
            grid-snapshot
            #:component component
            #:floor-db floor-db
            #:normalize? normalize?
            #:scale radial-scale
            #:palette palette-snapshot
            #:color-stops stops-snapshot
            #:mesh-step mesh-step
            #:spherical-grid? grid-visible-snapshot))
         (queue-in-eventspace
          eventspace
          (lambda ()
            ;; A later slider movement makes this completed surface stale.
            ;; Discard it rather than flashing an obsolete ramp on screen.
            (when (= generation render-generation)
              (send canvas replace-scene new-surface new-center new-radius)
              (send legend set-palette palette-snapshot stops-snapshot)
              (send legend set-peak-gain new-peak)
              (send status set-label
                    (string-append
                     "drag to orbit  |  wheel to zoom  |  "
                     "COPY STOPS exports this ramp")))))))))
  (define (replace-stop index new-db)
    (set! current-stops
          (for/list ([stop (in-list current-stops)]
                     [candidate-index (in-naturals)])
            (if (= candidate-index index)
                (cons new-db (cdr stop))
                stop))))
  (define (rebuild-stop-controls!)
    (send stops-panel change-children (lambda (_children) '()))
    (define count (length current-stops))
    (for ([stop (in-list current-stops)]
          [index (in-naturals)])
      (define row
        (new horizontal-panel%
             [parent stops-panel]
             [stretchable-height #f]
             [alignment '(left center)]))
      (new color-swatch% [parent row] [rgb (cdr stop)])
      (define value-label
        (new message%
             [parent row]
             [label (format "~a dB" (real->decimal-string
                                      (exact->inexact (car stop)) 2))]
             [min-width 76]))
      (define slider
        (new slider%
             [parent row]
             [label ""]
             [min-value 0]
             [max-value 300]
             [init-value (exact-round (* 10 (+ 30 (car stop))))]
             [style '(horizontal plain)]
             [callback
              (lambda (control _event)
                (define requested (- (/ (send control get-value) 10.0) 30.0))
                (define lower
                  (if (zero? index) -30.0
                      (+ (car (list-ref current-stops (sub1 index))) 0.1)))
                (define upper
                  (if (= index (sub1 count)) 0.0
                      (- (car (list-ref current-stops (add1 index))) 0.1)))
                (define adjusted (max lower (min upper requested)))
                (unless (= (send control get-value)
                           (exact-round (* 10 (+ adjusted 30))))
                  (send control set-value
                        (exact-round (* 10 (+ adjusted 30)))))
                (replace-stop index adjusted)
                (send value-label set-label
                      (format "~a dB"
                              (real->decimal-string adjusted 2)))
                (schedule-render!))]))
      ;; The palette must still span the complete -30…0 dB legend. Interior
      ;; stops are the degrees of freedom being investigated.
      (when (or (zero? index) (= index (sub1 count)))
        (send slider enable #f))))
  (rebuild-stop-controls!)
  (send frame show #t)
  (make-opengl-handle
   frame
   (lambda (new-grid)
     (unless (nec2c-pattern-grid? new-grid)
       (raise-argument-error
        'visualization-update! "nec2c-pattern-grid?" new-grid))
     (set! current-grid new-grid)
     (define-values (new-surface new-radius new-center new-peak)
       (build-radiation-pict3d
        new-grid
        #:component component
        #:floor-db floor-db
        #:normalize? normalize?
        #:scale radial-scale
        #:palette current-palette
        #:color-stops current-stops
        #:mesh-step mesh-step
        #:spherical-grid? show-grid?))
     (define new-edges (and antenna? (model-edges)))
     (queue-in-eventspace
      eventspace
      (lambda ()
        (send canvas replace-scene new-surface new-center new-radius)
        (send legend set-peak-gain new-peak)
        (when antenna-canvas
          (send antenna-canvas set-edges new-edges)))))))

(define (validate-comparison-cases who cases [expected-count #f])
  (unless (and (list? cases) (<= 1 (length cases) 9))
    (raise-argument-error who "(list/c radiation-case?){1,9}" cases))
  (when (and expected-count (not (= (length cases) expected-count)))
    (raise-arguments-error
     who
     "the updated comparison must contain the original number of cases"
     "expected cases" expected-count
     "received cases" (length cases)))
  (for ([item (in-list cases)])
    (unless (radiation-case? item)
      (raise-argument-error who "(listof radiation-case?)" cases))
    (unless (string? (radiation-case-title item))
      (raise-argument-error who
                            "radiation cases with string titles" cases))
    (unless (nec2c-pattern-grid? (radiation-case-grid item))
      (raise-argument-error who
                            "radiation cases with nec2c-pattern-grid values"
                            cases))))

(define (comparison-data cases component floor-db radial-scale palette
                         color-step mesh-step drag-mesh-step
                         difference-mode difference-range-db)
  (define difference? (and difference-mode #t))
  (define surface-difference? (eq? difference-mode 'surface))
  (define local-peaks
    (for/list ([item (in-list cases)])
      (component-peak (radiation-case-grid item) component)))
  (define shared-peak (apply max local-peaks))
  (define effective-difference-range-db
    (if (eq? difference-range-db 'auto)
        (automatic-difference-range cases component)
        difference-range-db))
  (define reference-grid (radiation-case-grid (first cases)))
  (define geometry-peak
    (if difference? (first local-peaks) shared-peak))
  (define scene-data
    (for/list ([item (in-list cases)]
               [index (in-naturals)])
      (define candidate-grid (radiation-case-grid item))
      (define grid (if (and difference? (positive? index))
                       reference-grid
                       candidate-grid))
      (define color-at
        (and difference? (positive? index)
             (difference-color-function
              reference-grid candidate-grid component
              effective-difference-range-db)))
      (define radius-at
        (and surface-difference? (positive? index)
             (difference-radius-function
              reference-grid candidate-grid component
              floor-db radial-scale geometry-peak)))
      (define-values (surface radius center _local-peak)
        (build-radiation-pict3d
         grid
         #:component component
         #:floor-db floor-db
         #:normalize? #t
         #:scale radial-scale
         #:palette palette
         #:color-step color-step
         #:mesh-step mesh-step
         #:reference-peak geometry-peak
         #:color-at color-at
         #:radius-at radius-at))
      (define proxy-polylines
        (comparison-proxy-polylines
         grid component floor-db radial-scale geometry-peak drag-mesh-step
         radius-at))
      (list surface proxy-polylines radius center)))
  (values local-peaks geometry-peak scene-data
          (apply max (map third scene-data))
          effective-difference-range-db))

(define (comparison-tile-label item peak difference-mode index)
  (format "~a — ~a dBi peak~a"
          (radiation-case-title item)
          (real->decimal-string (exact->inexact peak) 1)
          (cond [(not difference-mode) ""]
                [(zero? index) " — reference"]
                [(eq? difference-mode 'surface) " — Δ surface from reference"]
                [else " — Δ color from reference"])))

(define (normalize-difference-mode who value)
  (cond [(not value) #f]
        [(eq? value #t) 'color]
        [(memq value '(color surface)) value]
        [else
         (raise-argument-error
          who "(or/c #f #t 'color 'surface)" value)]))

(define (show-radiation-comparison cases
                                   #:component [component 'total]
                                   #:floor-db [floor-db -40]
                                   #:scale [radial-scale 'arrl]
                                   #:palette [palette 'mmana]
                                   #:color-step [color-step #f]
                                   #:difference? [difference? #f]
                                   #:difference-range-db [difference-range-db 'auto]
                                   #:mesh-step [mesh-step 2]
                                   #:aspect-ratio [aspect-ratio 16/9]
                                   #:width [width 1400])
  (validate-comparison-cases 'show-radiation-comparison cases)
  (define difference-mode
    (normalize-difference-mode 'show-radiation-comparison difference?))
  (unless (or (eq? difference-range-db 'auto)
              (and (real? difference-range-db)
                   (positive? difference-range-db)))
    (raise-argument-error
     'show-radiation-comparison "(or/c 'auto positive-real?)"
     difference-range-db))
  (when difference-mode
    (validate-difference-grids 'show-radiation-comparison cases))
  (unless (and (real? floor-db) (< floor-db 0))
    (raise-argument-error 'show-radiation-comparison "negative-real?" floor-db))
  (unless (and (real? mesh-step) (positive? mesh-step))
    (raise-argument-error 'show-radiation-comparison "positive-real?" mesh-step))
  (unless (and (real? aspect-ratio) (positive? aspect-ratio))
    (raise-argument-error 'show-radiation-comparison
                          "positive-real?" aspect-ratio))
  (unless (and (exact-integer? width) (positive? width))
    (raise-argument-error 'show-radiation-comparison
                          "exact-positive-integer?" width))
  (validate-radial-scale 'show-radiation-comparison radial-scale)
  (validate-color-step 'show-radiation-comparison color-step)
  (define color-stops
    (resolve-palette 'show-radiation-comparison palette))
  ;; The drag proxy is projected and drawn in 2-D rather than sent through a
  ;; second OpenGL scene. It samples the same gain grid but carries only a
  ;; sparse set of latitude/longitude polylines.
  (define drag-mesh-step
    (min 20 (max 10 (* 4 mesh-step))))
  (define-values (local-peaks shared-peak scene-data shared-radius
                              effective-difference-range-db)
    (comparison-data cases component floor-db radial-scale palette
                     color-step mesh-step drag-mesh-step
                     difference-mode difference-range-db))
  (define height (max 1 (exact-round (/ width aspect-ratio))))
  (define-values (rows columns)
    (comparison-layout (length cases) width height
                       (if difference-mode 174 112)))
  (define frame
    (new frame%
         [label "NEC2C radiation pattern comparison"]
         [width width]
         [height height]))
  (define eventspace (current-eventspace))
  (define root (new vertical-panel% [parent frame] [spacing 0]))
  (define tile-area
    (new vertical-panel% [parent root] [spacing 2]))
  (define footer
    (new horizontal-panel%
         [parent root]
         [alignment '(left center)]
         [stretchable-height #f]
         [spacing 0]))
  (define orientation-canvas
    (new orientation-canvas% [parent footer]))
  (define legend-panel
    (new vertical-panel%
         [parent footer]
         [spacing 0]
         [stretchable-width #t]
         [stretchable-height #f]))
  (define legend
    (new horizontal-legend-canvas%
         [parent legend-panel]
         [radial-scale radial-scale]
         [palette palette]
         [color-stops color-stops]
         [peak-gain shared-peak]
         [color-step color-step]))
  (define difference-legend
    (and difference-mode
         (new difference-legend-canvas%
              [parent legend-panel]
              [range-db effective-difference-range-db])))
  (define status
    (new message%
         [parent root]
         [label "drag any pattern to orbit  |  wheel to zoom"]
         [stretchable-width #t]))
  (define controller
    (new comparison-controller%
         [orientation-canvas orientation-canvas]
         [status-label status]))
  (define tiles '())
  (define canvases '())
  (define proxies '())
  (parameterize ([current-pict3d-background (rgba "black")]
                 [current-pict3d-ambient (emitted "white" 1.0)]
                 [current-pict3d-fov view-fov-degrees])
    (for ([row-index (in-range rows)])
      (define row
        (new horizontal-panel% [parent tile-area] [spacing 2]))
      (for ([column-index (in-range columns)])
        (define index (+ (* row-index columns) column-index))
        (cond
          [(< index (length cases))
           (define item (list-ref cases index))
           (define data (list-ref scene-data index))
           (define tile
             (new group-box-panel%
                  [parent row]
                  [label
                    (comparison-tile-label
                     item (list-ref local-peaks index) difference-mode index)]
                  [alignment '(center center)]))
           (define view-host
             (new vertical-panel% [parent tile] [spacing 0]))
           (define canvas
             (new comparison-orbit-canvas%
                  [parent view-host]
                  [surface (first data)]
                  [radius shared-radius]
                  [view-center (fourth data)]
                  [controller controller]))
           (define proxy
             (new comparison-proxy-canvas%
                  [parent view-host]
                  [polylines (second data)]
                  [radius shared-radius]
                  [view-center (fourth data)]
                  [controller controller]))
           (send view-host change-children
                 (lambda (_children) (list canvas)))
           (send controller register view-host canvas proxy)
           (set! tiles (cons tile tiles))
           (set! canvases (cons canvas canvases))
           (set! proxies (cons proxy proxies))
           (send canvas set-async-updates? #t)]
          [else
           ;; Preserve the selected rectangular grid when the last row is not
           ;; full; changing column widths would make the final tiles larger.
           (new vertical-panel% [parent row])]))))
  ;; Construction walks row-major but accumulation above is by cons.
  (set! tiles (reverse tiles))
  (set! canvases (reverse canvases))
  (set! proxies (reverse proxies))
  (send frame show #t)
  (define case-count (length cases))
  (make-opengl-handle
   frame
   (lambda (new-cases)
     (validate-comparison-cases
      'visualization-update! new-cases case-count)
     (when difference-mode
       (validate-difference-grids 'visualization-update! new-cases))
     (define-values (new-local-peaks new-shared-peak
                                    new-scene-data new-shared-radius
                                    new-effective-difference-range-db)
       (comparison-data new-cases component floor-db radial-scale palette
                        color-step mesh-step drag-mesh-step
                        difference-mode difference-range-db))
     (queue-in-eventspace
      eventspace
      (lambda ()
        (for ([item (in-list new-cases)]
              [peak (in-list new-local-peaks)]
              [data (in-list new-scene-data)]
              [tile (in-list tiles)]
              [canvas (in-list canvases)]
              [proxy (in-list proxies)]
              [index (in-naturals)])
          (send tile set-label
                (comparison-tile-label item peak difference-mode index))
          (send canvas replace-scene
                (first data) (fourth data) new-shared-radius)
          (send proxy replace-polylines
                (second data) (fourth data) new-shared-radius))
        (send legend set-peak-gain new-shared-peak)
        (when difference-legend
          (send difference-legend set-range-db
                new-effective-difference-range-db))
        (send controller refresh-view))))))
