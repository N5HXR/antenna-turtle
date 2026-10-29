#lang racket/base

(require pict3d
         racket/class
         racket/gui/base
         racket/list
         racket/math
         (only-in "core.rkt"
                  model-edges
                  point3 point3-x point3-y point3-z
                  vertex-point
                  wire-edge-start wire-edge-end wire-edge-feed?
                  wire-edge-feed-location)
         "radiation-case.rkt"
         "visualization-handle.rkt"
         "nec2c.rkt")

(provide show-radiation-pattern-opengl
         show-radiation-comparison
         radiation-grid->pict3d)

;; The default nonlinear stops resemble MMANA and concentrate visual
;; resolution in the first 10 dB below peak. The other ramps are sampled from
;; familiar scientific-visualization palettes over the full 30 dB legend.
(define mmana-color-stops
  '((-30 . (12 20 180))
    (-20 . (0 100 255))
    (-10 . (0 230 255))
    (-6  . (0 238 95))
    (-3  . (235 255 18))
    (-1.5 . (255 192 18))
    (-0.5 . (255 58 18))
    (0 . (255 20 205))))

(define magma-color-stops
  '((-30 . (0 0 4))
    (-26.25 . (28 16 68))
    (-22.5 . (79 18 123))
    (-18.75 . (129 37 129))
    (-15 . (181 54 122))
    (-11.25 . (229 80 100))
    (-7.5 . (251 135 97))
    (-3.75 . (254 194 135))
    (0 . (252 253 191))))

(define inferno-color-stops
  '((-30 . (0 0 4))
    (-26.25 . (31 12 72))
    (-22.5 . (85 15 109))
    (-18.75 . (136 34 106))
    (-15 . (186 54 85))
    (-11.25 . (227 89 51))
    (-7.5 . (249 140 10))
    (-3.75 . (249 201 50))
    (0 . (252 255 164))))

(define viridis-color-stops
  '((-30 . (68 1 84))
    (-26.25 . (72 40 120))
    (-22.5 . (62 74 137))
    (-18.75 . (49 104 142))
    (-15 . (38 130 142))
    (-11.25 . (31 158 137))
    (-7.5 . (53 183 121))
    (-3.75 . (109 205 89))
    (0 . (253 231 37))))

(define grayscale-color-stops
  '((-30 . (24 24 24))
    (-20 . (92 92 92))
    (-10 . (174 174 174))
    (0 . (255 255 255))))

(define hot-eletric-stops
  '((-30    . (0 0 4))
    (-26.25 . (0 0 48))
    (-22.5  . (0 0 105))
    (-18.75 . (35 0 145))
    (-15    . (85 0 175))
    (-11.25 . (145 0 205))
    (-7.5   . (215 0 235))
    (-3.75  . (255 45 245))
    (0      . (255 190 255))))

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
                                #:color-step [color-step #f]
                                #:mesh-step [mesh-step 2]
                                #:axes? [axes? #f]
                                #:reference-peak [reference-peak #f]
                                #:color-at [color-at #f])
  (unless (nec2c-pattern-grid? grid)
    (raise-argument-error 'radiation-grid->pict3d "nec2c-pattern-grid?" grid))
  (unless (and (real? floor-db) (< floor-db 0))
    (raise-argument-error 'radiation-grid->pict3d "negative-real?" floor-db))
  (unless (and (real? mesh-step) (positive? mesh-step))
    (raise-argument-error 'radiation-grid->pict3d "positive-real?" mesh-step))
  (unless (boolean? axes?)
    (raise-argument-error 'radiation-grid->pict3d "boolean?" axes?))
  (validate-color-step 'radiation-grid->pict3d color-step)
  (validate-radial-scale 'radiation-grid->pict3d radial-scale)
  (define color-stops (resolve-palette 'radiation-grid->pict3d palette))
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
  (define (radius-for sample)
    (define gain (sample-gain sample component))
    (if (real? gain)
        (scaled-radius gain display-peak floor-db normalize? radial-scale)
        0))
  (define (relative-gain-at theta-deg phi-deg)
    (define gain (sample-gain (grid-sample theta-deg phi-deg) component))
    (if (real? gain) (- gain display-peak) -30))
  (define (make-surface-vertex theta-deg phi-deg [face-color-db #f])
    (define sample (grid-sample theta-deg phi-deg))
    (define radius (radius-for sample))
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
            (define radius (radius-for sample))
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
      (define radius (radius-for sample))
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
  (values (if axes?
              (freeze (combine surface (coordinate-triad view-radius)))
              surface)
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
                                    reference-peak mesh-step)
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
      (if (real? gain)
          (scaled-radius gain reference-peak floor-db #t radial-scale)
          0))
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

(define (make-opengl-handle frame update-procedure)
  (make-visualization-handle
   update-procedure
   (lambda () (send frame show #t))
   (lambda () (send frame show #f))
   (lambda () (send frame is-shown?))))

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
                         difference? difference-range-db)
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
         #:color-at color-at))
      (define proxy-polylines
        (comparison-proxy-polylines
         grid component floor-db radial-scale geometry-peak drag-mesh-step))
      (list surface proxy-polylines radius center)))
  (values local-peaks geometry-peak scene-data
          (apply max (map third scene-data))
          effective-difference-range-db))

(define (comparison-tile-label item peak difference? index)
  (format "~a — ~a dBi peak~a"
          (radiation-case-title item)
          (real->decimal-string (exact->inexact peak) 1)
          (cond [(not difference?) ""]
                [(zero? index) " — reference"]
                [else " — Δ from reference"])))

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
  (unless (boolean? difference?)
    (raise-argument-error 'show-radiation-comparison "boolean?" difference?))
  (unless (or (eq? difference-range-db 'auto)
              (and (real? difference-range-db)
                   (positive? difference-range-db)))
    (raise-argument-error
     'show-radiation-comparison "(or/c 'auto positive-real?)"
     difference-range-db))
  (when difference?
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
                     difference? difference-range-db))
  (define height (max 1 (exact-round (/ width aspect-ratio))))
  (define-values (rows columns)
    (comparison-layout (length cases) width height
                       (if difference? 174 112)))
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
    (and difference?
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
                     item (list-ref local-peaks index) difference? index)]
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
     (when difference?
       (validate-difference-grids 'visualization-update! new-cases))
     (define-values (new-local-peaks new-shared-peak
                                    new-scene-data new-shared-radius
                                    new-effective-difference-range-db)
       (comparison-data new-cases component floor-db radial-scale palette
                        color-step mesh-step drag-mesh-step
                        difference? difference-range-db))
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
                (comparison-tile-label item peak difference? index))
          (send canvas replace-scene
                (first data) (fourth data) new-shared-radius)
          (send proxy replace-polylines
                (second data) (fourth data) new-shared-radius))
        (send legend set-peak-gain new-shared-peak)
        (when difference-legend
          (send difference-legend set-range-db
                new-effective-difference-range-db))
        (send controller refresh-view))))))
