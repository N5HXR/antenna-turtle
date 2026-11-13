#lang racket/base

(require pict3d
         racket/class
         racket/format
         racket/gui/base
         racket/list
         racket/math
         (only-in "core.rkt"
                  model-edges point3-x point3-y point3-z vertex-point
                  wire-edge-start wire-edge-end wire-edge-diameter
                  wire-edge-feed? wire-edge-feed-location)
         "near-field-particle.rkt"
         "near-field-polarization.rkt"
         "nec2c.rkt"
         "visualization-handle.rkt")

(provide show-near-field-polarization-point-poc
         near-field-glyph-sample-indices)

(define view-fov-degrees 34)
(define phase-degrees-per-second 180.0)
(define field-floor-db -30.0)
(define magma-levels '(-30 -25 -19 -15 -11 -7 -3 -1 0))
(define magma-colors
  '((0 0 4) (28 16 68) (79 18 123) (129 37 129) (181 54 122)
    (229 80 100) (251 135 97) (254 194 135) (252 253 191)))

(define (axis-coordinate point axis)
  (case axis
    [(x) (pos-x point)]
    [(y) (pos-y point)]
    [(z) (pos-z point)]
    [else (raise-argument-error 'axis-coordinate "(or/c 'x 'y 'z)" axis)]))

(define (axis-direction axis)
  (case axis
    [(x) (dir 1 0 0)]
    [(y) (dir 0 1 0)]
    [(z) (dir 0 0 1)]))

(define (list->pos values) (apply pos values))

(define (section-point section u v [normal-offset 0.0])
  (list->pos (near-field-plane-point section u v normal-offset)))

(define (sampled-values values [limit 31])
  (define count (length values))
  (define stride (max 1 (inexact->exact (ceiling (/ count limit)))))
  (remove-duplicates
   (append
    (for/list ([value (in-list values)] [index (in-naturals)]
               #:when (zero? (modulo index stride)))
      value)
    (list (last values)))))

(define (electric-magnitude electric)
  (sqrt
   (for/sum ([component (in-list electric)])
     (sqr (magnitude component)))))

(define (interpolate-list a b fraction)
  (for/list ([x (in-list a)] [y (in-list b)])
    (+ x (* fraction (- y x)))))

(define (magma-color db)
  (define bounded (max field-floor-db (min 0.0 db)))
  (let loop ([levels magma-levels] [colors magma-colors])
    (cond
      [(null? (rest levels)) (first colors)]
      [(<= bounded (second levels))
       (interpolate-list
        (first colors) (second colors)
        (/ (- bounded (first levels))
           (- (second levels) (first levels))))]
      [else (loop (rest levels) (rest colors))])))

(define (color->rgba color [alpha 1.0])
  (apply rgba
         (append (map (lambda (channel) (/ channel 255.0)) color)
                 (list alpha))))

(define (vector3-dot a b)
  (for/sum ([x (in-list a)] [y (in-list b)]) (* x y)))

(define (signed-power-color normalized)
  (define bounded (max -1.0 (min 1.0 normalized)))
  (define zero '(24 12 34))
  (if (negative? bounded)
      (interpolate-list zero '(38 190 255) (- bounded))
      (interpolate-list zero '(255 190 45) bounded)))

;; Pict3D's `pipe` occupies an axis-aligned bounding box; its two positional
;; arguments do not describe a general line segment. Build an exactly sized
;; +Z cylinder, then rotate and translate it onto the requested segment.
;; `point-at` rotates but (intentionally) does not scale, so both the local
;; cylinder length and its radius must already be in world units.
(define (tube-between start end radius)
  (define displacement (pos- end start))
  (define length
    (sqrt (+ (sqr (dir-dx displacement))
             (sqr (dir-dy displacement))
             (sqr (dir-dz displacement)))))
  (if (<= length 1e-15)
      empty-pict3d
      (transform
       (cylinder (pos 0 0 (/ length 2.0))
                 (dir (* 2.0 radius) (* 2.0 radius) length))
       (point-at start end))))

(define (cone-between base tip radius)
  (define displacement (pos- tip base))
  (define length
    (sqrt (+ (sqr (dir-dx displacement))
             (sqr (dir-dy displacement))
             (sqr (dir-dz displacement)))))
  (if (<= length 1e-15)
      empty-pict3d
      (transform
       (cone (pos 0 0 (/ length 2.0))
             (dir radius radius (/ length 2.0)))
       (point-at base tip))))

(define (diagram-arrow start displacement scene-radius)
  (define length (vector3-magnitude displacement))
  (if (<= length (* scene-radius 0.002))
      empty-pict3d
      (let* ([head-length (* length 0.34)]
             [shaft-fraction (/ (- length head-length) length)]
             [end (pos (+ (pos-x start) (first displacement))
                       (+ (pos-y start) (second displacement))
                       (+ (pos-z start) (third displacement)))]
             [head-base
              (pos (+ (pos-x start) (* shaft-fraction (first displacement)))
                   (+ (pos-y start) (* shaft-fraction (second displacement)))
                   (+ (pos-z start) (* shaft-fraction (third displacement))))]
             [width-scale
              (min 1.0 (/ length (* scene-radius 0.050)))]
             [shaft-radius (* scene-radius 0.0017 width-scale)]
             [head-radius (* scene-radius 0.0068 width-scale)])
        (combine (tube-between start head-base shaft-radius)
                 (cone-between head-base end head-radius)))))

(define heatmap-material
  (material #:ambient 0.90 #:diffuse 0.10 #:specular 0.0 #:roughness 1.0))

(define (make-field-map field scene-radius [quantity 'electric])
  (unless (memq quantity '(electric average-power signed-normal-power))
    (raise-argument-error
     'make-field-map
     "(or/c 'electric 'average-power 'signed-normal-power)" quantity))
  (define section (near-field-flow-field-section field))
  (define u-values (nec2c-near-field-section-u-values section))
  (define v-values (nec2c-near-field-section-v-values section))
  (define u-min (first u-values))
  (define u-max (last u-values))
  (define v-min (first v-values))
  (define v-max (last v-values))
  (define normal-list
    (case (nec2c-near-field-section-normal-axis section)
      [(x) '(1.0 0.0 0.0)]
      [(y) '(0.0 1.0 0.0)]
      [(z) '(0.0 0.0 1.0)]))
  (define (quantity-value u v)
    (case quantity
      [(electric) (electric-magnitude (near-field-flow-electric field u v))]
      [else
       (define poynting
         (or (near-field-flow-average-poynting field u v) '(0.0 0.0 0.0)))
       (if (eq? quantity 'average-power)
           (vector3-magnitude poynting)
           (vector3-dot poynting normal-list))]))
  (define quantity-values
    (sort
     (for/list ([sample (in-list
                         (nec2c-near-field-section-samples section))])
       (define electric (nec2c-near-field-sample-electric sample))
       (define magnetic (nec2c-near-field-sample-magnetic sample))
       (define value
         (case quantity
           [(electric) (electric-magnitude electric)]
           [else
            (define poynting
              (map (lambda (component) (* 0.5 (real-part component)))
                   (list (- (* (second electric) (conjugate (third magnetic)))
                            (* (third electric) (conjugate (second magnetic))))
                         (- (* (third electric) (conjugate (first magnetic)))
                            (* (first electric) (conjugate (third magnetic))))
                         (- (* (first electric) (conjugate (second magnetic)))
                            (* (second electric) (conjugate (first magnetic)))))))
            (if (eq? quantity 'average-power)
                (vector3-magnitude poynting)
                (vector3-dot poynting normal-list))]))
       (if (eq? quantity 'signed-normal-power) (abs value) value))
     <))
  ;; A conductor-adjacent sample can be orders of magnitude above the rest of
  ;; the plane. A p98 display reference preserves the surrounding structure
  ;; while allowing the hottest two percent to saturate harmlessly.
  (define peak
    (if (null? quantity-values)
        0.0
        (list-ref quantity-values
                  (inexact->exact
                   (floor (* 0.98 (sub1 (length quantity-values))))))))
  (define sampled-u (sampled-values u-values 45))
  (define sampled-v (sampled-values v-values 45))
  (define offset (* scene-radius 0.0012))
  (define normal
    (axis-direction (nec2c-near-field-section-normal-axis section)))
  (define (heat-vertex u v normal-direction)
      (define value (quantity-value u v))
      (define color
        (cond
          [(eq? quantity 'signed-normal-power)
           (signed-power-color (if (positive? peak) (/ value peak) 0.0))]
          [else
           (define relative-db
             (if (and (positive? peak) (positive? value))
                 (* (if (eq? quantity 'electric) 20.0 10.0)
                    (/ (log (/ value peak)) (log 10.0)))
                 field-floor-db))
           (magma-color relative-db)]))
      (vertex (section-point section u v offset)
              #:normal normal-direction
              #:color (color->rgba color 0.58)
              #:emitted (apply emitted
                               (append (map (lambda (channel)
                                              (* 0.16 (/ channel 255.0)))
                                            color)
                                       '(0.58)))
              #:material heatmap-material))
  (define (cell u0 u1 v0 v1 normal-direction reverse?)
    (define a (heat-vertex u0 v0 normal-direction))
    (define b (heat-vertex u1 v0 normal-direction))
    (define c (heat-vertex u1 v1 normal-direction))
    (define d (heat-vertex u0 v1 normal-direction))
    (if reverse?
        (combine (triangle a c b) (triangle a d c))
        (combine (triangle a b c) (triangle a c d))))
  ;; Vertex colors are interpolated across the triangles, yielding a continuous
  ;; translucent magnitude field instead of a visually ambiguous sample lattice.
  (define surface
    (for*/list ([v-index (in-range (sub1 (length sampled-v)))]
                [u-index (in-range (sub1 (length sampled-u)))])
      (define u0 (list-ref sampled-u u-index))
      (define u1 (list-ref sampled-u (add1 u-index)))
      (define v0 (list-ref sampled-v v-index))
      (define v1 (list-ref sampled-v (add1 v-index)))
      (combine (cell u0 u1 v0 v1 normal #f)
               (cell u0 u1 v0 v1 (dir-negate normal) #t))))
  (define frame-radius (* scene-radius 0.0015))
  (define corners
    (list (section-point section u-min v-min offset)
          (section-point section u-max v-min offset)
          (section-point section u-max v-max offset)
          (section-point section u-min v-max offset)))
  (define boundary
    (with-color (rgba 0.25 0.88 1.0 0.82)
      (with-emitted (emitted 0.16 0.65 0.82 0.72)
        (combine
         (for/list ([start (in-list corners)]
                    [end (in-list (append (rest corners)
                                          (list (first corners))))])
           (tube-between start end frame-radius))))))
  (values (freeze (combine surface boundary)) peak))

(define (point3->pos point)
  (pos (point3-x point) (point3-y point) (point3-z point)))

(define (edge-point edge location)
  (define start (vertex-point (wire-edge-start edge)))
  (define end (vertex-point (wire-edge-end edge)))
  (case location
    [(start) start]
    [(end) end]
    [else
     (list->pos
      (list (/ (+ (point3-x start) (point3-x end)) 2.0)
            (/ (+ (point3-y start) (point3-y end)) 2.0)
            (/ (+ (point3-z start) (point3-z end)) 2.0)))]))

(define (make-antenna-reference edges scene-radius)
  ;; True wire diameters often collapse below one pixel at plane scale. Keep
  ;; their centerlines physical but enforce a diagrammatic readable width.
  (define presentation-radius (* scene-radius 0.0032))
  (define conductors
    (for/list ([edge (in-list edges)])
      (define radius
        (max presentation-radius (/ (wire-edge-diameter edge) 2.0)))
      (define start (point3->pos (vertex-point (wire-edge-start edge))))
      (define end (point3->pos (vertex-point (wire-edge-end edge))))
      (with-color (rgba 0.08 0.92 1.0 1.0)
        (with-emitted (emitted 0.08 0.92 1.0 1.0)
          (tube-between start end radius)))))
  (define feeds
    (for/list ([edge (in-list edges)] #:when (wire-edge-feed? edge))
      (define point (edge-point edge (wire-edge-feed-location edge)))
      (with-color (rgba 1.0 0.08 0.62 1.0)
        (with-emitted (emitted 1.0 0.04 0.50 1.0)
          (sphere (if (pos? point) point (point3->pos point))
                  (* scene-radius 0.010))))))
  (freeze (combine conductors feeds)))

(define (make-coordinate-reference scene-radius)
  (define length (* scene-radius 0.060))
  (freeze
   (combine
    (with-color (rgba 1.0 0.05 0.05 0.38)
      (with-emitted (emitted 0.24 0.01 0.01 0.38)
        (arrow origin (dir length 0 0))))
    (with-color (rgba 0.05 0.22 1.0 0.38)
      (with-emitted (emitted 0.01 0.06 0.26 0.38)
        (arrow origin (dir 0 length 0))))
    (with-color (rgba 0.05 1.0 0.15 0.38)
      (with-emitted (emitted 0.01 0.24 0.04 0.38)
        (arrow origin (dir 0 0 length)))))))

(define invisible-material
  (material #:ambient 0.0 #:diffuse 0.0 #:specular 0.0 #:roughness 1.0))

(define (make-hit-plane section)
  (define u-values (nec2c-near-field-section-u-values section))
  (define v-values (nec2c-near-field-section-v-values section))
  (define u-min (first u-values))
  (define u-max (last u-values))
  (define v-min (first v-values))
  (define v-max (last v-values))
  (define normal (axis-direction (nec2c-near-field-section-normal-axis section)))
  (define (vtx u v)
    (vertex (section-point section u v)
            #:normal normal
            #:color (rgba 0 0 0 0)
            #:material invisible-material))
  (define a (vtx u-min v-min))
  (define b (vtx u-max v-min))
  (define c (vtx u-max v-max))
  (define d (vtx u-min v-max))
  (combine (triangle a b c) (triangle a c d)))

(define (scene-dimensions section)
  (define u-values (nec2c-near-field-section-u-values section))
  (define v-values (nec2c-near-field-section-v-values section))
  (define u-min (first u-values))
  (define u-max (last u-values))
  (define v-min (first v-values))
  (define v-max (last v-values))
  (define center
    (section-point section (/ (+ u-min u-max) 2.0) (/ (+ v-min v-max) 2.0)))
  (define radius
    (max 1e-6 (* 0.55 (sqrt (+ (sqr (- u-max u-min))
                                (sqr (- v-max v-min)))))))
  (values center radius))

(define (camera-affine center radius azimuth altitude zoom)
  (define az (degrees->radians azimuth))
  (define alt (degrees->radians altitude))
  (define distance (* radius zoom))
  (point-at
   (pos (+ (pos-x center) (* distance (cos alt) (cos az)))
        (+ (pos-y center) (* distance (cos alt) (sin az)))
        (+ (pos-z center) (* distance (sin alt))))
   center))

(define (camera-scene scene center radius azimuth altitude zoom)
  (combine scene
           (basis 'camera (camera-affine center radius azimuth altitude zoom))))

(define (electric-offset center electric scale)
  (pos (+ (pos-x center) (* scale (first electric)))
       (+ (pos-y center) (* scale (second electric)))
       (+ (pos-z center) (* scale (third electric)))))

(define (make-trajectory center ellipse scene-radius)
  (if (not ellipse)
      empty-pict3d
      (let* ([major
              (near-field-polarization-ellipse-major-amplitude ellipse)]
             [scale (/ (* scene-radius 0.14) major)]
             [dot-radius (* scene-radius 0.0042)]
             [electric
              (near-field-polarization-ellipse-electric ellipse)])
        (freeze
         (with-color (rgba 1 1 1 1)
           (with-emitted (emitted 1 1 1 1)
             (combine
              (for/list ([index (in-range 96)])
                (define phase (* 2 pi (/ index 96.0)))
                (sphere
                 (electric-offset
                  center
                  (near-field-instantaneous-electric electric phase)
                  scale)
                 dot-radius)))))))))

(define (make-bead center ellipse scene-radius phase-degrees)
  (if (not ellipse)
      empty-pict3d
      (let* ([major
              (near-field-polarization-ellipse-major-amplitude ellipse)]
             [scale (/ (* scene-radius 0.14) major)]
             [electric
              (near-field-polarization-ellipse-electric ellipse)]
             [instantaneous
              (near-field-instantaneous-electric
               electric (degrees->radians phase-degrees))]
             [point (electric-offset center instantaneous scale)])
        (with-color (rgba 1 1 1 1)
          (with-emitted (emitted 1 1 1 1)
            (sphere point (* scene-radius 0.014)))))))

(define (near-field-glyph-sample-indices count stride)
  (unless (and (exact-integer? count) (positive? count))
    (raise-argument-error
     'near-field-glyph-sample-indices "exact-positive-integer?" count))
  (unless (and (exact-integer? stride) (positive? stride))
    (raise-argument-error
     'near-field-glyph-sample-indices "exact-positive-integer?" stride))
  (sort
   (remove-duplicates
    (append (for/list ([index (in-range 0 count stride)]) index)
            (list (quotient (sub1 count) 2) (sub1 count))))
   <))

(struct near-field-glyph-instance (center ellipse u v) #:transparent)

(define (make-near-field-glyph-layout field stride)
  (define section (near-field-flow-field-section field))
  (define u-values (nec2c-near-field-section-u-values section))
  (define v-values (nec2c-near-field-section-v-values section))
  (define u-indices
    (near-field-glyph-sample-indices (length u-values) stride))
  (define v-indices
    (near-field-glyph-sample-indices (length v-values) stride))
  (filter
   values
   (for*/list ([v-index (in-list v-indices)]
               [u-index (in-list u-indices)])
     (define u (list-ref u-values u-index))
     (define v (list-ref v-values v-index))
     (define ellipse (near-field-polarization-at field u v))
     (and ellipse
          (near-field-glyph-instance
           (section-point section u v) ellipse u v)))))

(define (glyph-electric-point instance glyph-radius phase-radians)
  (define ellipse (near-field-glyph-instance-ellipse instance))
  (define scale
    (/ glyph-radius
       (near-field-polarization-ellipse-major-amplitude ellipse)))
  (electric-offset
   (near-field-glyph-instance-center instance)
   (near-field-instantaneous-electric
    (near-field-polarization-ellipse-electric ellipse) phase-radians)
   scale))

(define (make-near-field-glyph-ring instance scene-radius)
  (define ellipse (near-field-glyph-instance-ellipse instance))
  (define glyph-radius (* scene-radius 0.026))
  (define line-radius (* scene-radius 0.00115))
  (define linear?
    (<= (near-field-polarization-ellipse-minor-amplitude ellipse)
        (* (near-field-polarization-ellipse-major-amplitude ellipse) 1e-4)))
  (with-color (rgba 1.0 1.0 1.0 0.80)
    (with-emitted (emitted 0.68 0.68 0.68 0.80)
      (if linear?
          (tube-between
           (glyph-electric-point instance glyph-radius 0.0)
           (glyph-electric-point instance glyph-radius pi)
           line-radius)
          (combine
           (for/list ([index (in-range 24)])
             (define phase0 (* 2.0 pi (/ index 24.0)))
             (define phase1 (* 2.0 pi (/ (add1 index) 24.0)))
             (tube-between
              (glyph-electric-point instance glyph-radius phase0)
              (glyph-electric-point instance glyph-radius phase1)
              line-radius)))))))

(define (make-near-field-glyph-rings layout scene-radius)
  (freeze
   (combine
    (for/list ([instance (in-list layout)])
      (make-near-field-glyph-ring instance scene-radius)))))

(define (make-near-field-glyph-beads layout scene-radius phase-degrees)
  (define glyph-radius (* scene-radius 0.026))
  (define bead-radius (* scene-radius 0.0038))
  (define phase-radians (degrees->radians phase-degrees))
  (with-color (rgba 1.0 1.0 1.0 0.95)
    (with-emitted (emitted 0.90 0.90 0.90 0.95)
      (combine
       (for/list ([instance (in-list layout)])
         (sphere (glyph-electric-point instance glyph-radius phase-radians)
                 bead-radius))))))

(define (make-near-field-spin-arrows layout scene-radius)
  (define scale (* scene-radius 0.050))
  ;; Magma spends most of its range in purple, magenta, orange, and yellow.
  ;; Luminous cyan stays legible across both its dark and bright regions.
  (with-color (rgba 0.02 0.96 1.0 0.98)
    (with-emitted (emitted 0.02 0.78 0.88 0.98)
      (combine
       (for/list ([instance (in-list layout)])
         (define spin
           (near-field-electric-spin
            (near-field-polarization-ellipse-electric
             (near-field-glyph-instance-ellipse instance))))
         (if (> (vector3-magnitude spin) 1e-5)
             (diagram-arrow
              (near-field-glyph-instance-center instance)
              (map (lambda (x) (* scale x)) spin)
              scene-radius)
             empty-pict3d))))))

(define (make-near-field-power-arrows layout field scene-radius)
  ;; Pict3D's arrow head is a fixed fraction of total length.  The shorter M10
  ;; prototype therefore read as a round rivet, especially when viewed nearly
  ;; along Pavg.  A longer glyph restores a recognizable shaft/head silhouette.
  (define length (* scene-radius 0.095))
  (with-color (rgba 1.0 0.82 0.08 0.96)
    (with-emitted (emitted 0.78 0.52 0.02 0.96)
      (combine
       (for/list ([instance (in-list layout)])
         (define poynting
           (or (near-field-flow-average-poynting
                field
                (near-field-glyph-instance-u instance)
                (near-field-glyph-instance-v instance))
               '(0.0 0.0 0.0)))
         (define magnitude (vector3-magnitude poynting))
         (if (> magnitude 1e-30)
             (diagram-arrow
              (near-field-glyph-instance-center instance)
              (map (lambda (x) (* length (/ x magnitude))) poynting)
              scene-radius)
             empty-pict3d))))))

(define (make-marker center scene-radius)
  (with-color (rgba 1 0.2 0.75 1)
    (with-emitted (emitted 1 0.15 0.7 1)
      (sphere center (* scene-radius 0.012)))))

(define (make-origin-guide center scene-radius)
  (with-color (rgba 0.82 0.90 0.96 0.30)
    (with-emitted (emitted 0.10 0.13 0.16 0.30)
      (tube-between origin center (* scene-radius 0.0013)))))

(define (vector3-magnitude values)
  (sqrt (for/sum ([value (in-list values)]) (sqr value))))

(define (make-poynting-arrow center poynting scene-radius kind)
  (define magnitude (vector3-magnitude poynting))
  (if (<= magnitude 1e-30)
      empty-pict3d
      (let* ([scale (/ (* scene-radius 0.18) magnitude)]
             [average? (eq? kind 'average)])
        (with-color (if average?
                        (rgba 1.0 0.52 0.04 0.32)
                        (rgba 1.0 1.0 0.10 1.0))
          (with-emitted (if average?
                            (emitted 0.22 0.08 0.01 0.32)
                            (emitted 1.0 0.92 0.04 1.0))
            (arrow center
                   (apply dir
                          (map (lambda (component) (* scale component))
                               poynting))))))))

(define (normalize-degrees degrees)
  (- degrees (* 360.0 (floor (/ degrees 360.0)))))

(define (format-real value [digits 3])
  (~r (exact->inexact value) #:precision digits))

(define (format-complex value)
  (format "~a ~a j~a"
          (format-real (real-part value))
          (if (negative? (imag-part value)) "-" "+")
          (format-real (abs (imag-part value)))))

(define near-field-point-canvas%
  (class pict3d-canvas%
    (init-field grid hit-plane center radius selection-callback status-label)
    (init-field selection-cleared-callback)
    (define azimuth -42.0)
    (define altitude 24.0)
    (define zoom 2.7)
    (define dragging? #f)
    (define moved? #f)
    (define previous-x 0)
    (define previous-y 0)
    (define down-x 0)
    (define down-y 0)
    (define trajectory empty-pict3d)
    (define marker empty-pict3d)
    (define dynamic-scene empty-pict3d)
    (define glyph-rings empty-pict3d)
    (define glyph-beads empty-pict3d)
    (define display-base (freeze grid))
    (define (display-scene)
      (combine display-base dynamic-scene glyph-beads))
    (super-new
     [pict3d (camera-scene (display-scene) center radius
                           azimuth altitude zoom)])

    (define/private (refresh!)
      (send status-label set-label
            (format "drag to orbit  |  wheel to zoom  |  click plane to inspect  |  azimuth ~a degrees  elevation ~a degrees"
                    (exact-round azimuth) (exact-round altitude)))
      (parameterize ([current-pict3d-background (rgba "black")]
                     [current-pict3d-ambient (emitted "white" 1.0)]
                     [current-pict3d-fov view-fov-degrees])
        (send this set-pict3d
              (camera-scene (display-scene) center radius
                            azimuth altitude zoom))))

    (define/private (select-at! x y)
      (define-values (width height) (send this get-client-size))
      (when (and (> width 0) (> height 0))
        (define camera (camera-affine center radius azimuth altitude zoom))
        (define ray
          ((camera-ray-dir camera #:width width #:height height
                           #:fov view-fov-degrees) x y))
        (define hit (trace hit-plane (affine-origin camera) ray))
        (if hit
            (selection-callback hit)
            (selection-cleared-callback))))

    (define/public (set-selection-scenes! new-trajectory new-marker new-dynamic)
      (set! trajectory new-trajectory)
      (set! marker new-marker)
      (set! dynamic-scene new-dynamic)
      (set! display-base
            (freeze (combine grid glyph-rings trajectory marker)))
      (refresh!))

    (define/public (set-dynamic-scenes! new-dynamic new-glyph-beads)
      (set! dynamic-scene new-dynamic)
      (set! glyph-beads new-glyph-beads)
      (refresh!))

    (define/public (set-glyph-scenes! new-rings new-beads)
      (set! glyph-rings new-rings)
      (set! glyph-beads new-beads)
      (set! display-base
            (freeze (combine grid glyph-rings trajectory marker)))
      (refresh!))

    (define/public (set-reference-grid! new-grid)
      (set! grid new-grid)
      (set! display-base
            (freeze (combine grid glyph-rings trajectory marker)))
      (refresh!))

    (define/override (on-event event)
      (define type (send event get-event-type))
      (define x (send event get-x))
      (define y (send event get-y))
      (case type
        [(left-down)
         (set! dragging? #t)
         (set! moved? #f)
         (set! down-x x) (set! down-y y)
         (set! previous-x x) (set! previous-y y)]
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
                   (max -89.0 (min 89.0
                                    (+ altitude (* 0.45 (- y previous-y))))))
             (set! previous-x x) (set! previous-y y)
             (refresh!)))]
        [(wheel-up) (set! zoom (max 0.8 (* zoom 0.88))) (refresh!)]
        ;; A wide upper range is useful when the capture plane is far from a
        ;; physically small antenna or a selected trajectory points outward.
        [(wheel-down) (set! zoom (min 80.0 (/ zoom 0.88))) (refresh!)]
        [else (void)]))

    ;; Mouse-wheel events arrive as key events on Racket's GUI canvases. Keep
    ;; the on-event cases above for backend portability, but this is the normal
    ;; native path. The keyboard equivalents also aid trackpads and testing.
    (define/override (on-char event)
      (case (send event get-key-code)
        [(wheel-up #\+)
         (set! zoom (max 0.8 (* zoom 0.88)))
         (refresh!)]
        [(wheel-down #\-)
         (set! zoom (min 80.0 (/ zoom 0.88)))
         (refresh!)]
        [else (void)]))))

(define (show-near-field-polarization-point-poc
         result
         #:section [section-index 0]
         #:antenna? [antenna? #t]
         #:width [width 1180]
         #:height [height 780])
  (define who 'show-near-field-polarization-point-poc)
  (unless (nec2c-near-field-result? result)
    (raise-argument-error who "nec2c-near-field-result?" result))
  (unless (boolean? antenna?)
    (raise-argument-error who "boolean?" antenna?))
  (unless (and (exact-integer? section-index) (>= section-index 0)
               (< section-index
                  (length (nec2c-near-field-result-sections result))))
    (raise-arguments-error who "section index is outside the near-field result"
                           "section" section-index))
  (define section
    (list-ref (nec2c-near-field-result-sections result) section-index))
  (define field
    (make-near-field-flow-field
     section (nec2c-near-field-result-frequency-mhz result)))
  (define-values (view-center scene-radius) (scene-dimensions section))
  (define edges (if antenna? (model-edges) '()))
  (define background-quantity 'electric)
  (define-values (field-map field-peak)
    (make-field-map field scene-radius background-quantity))
  (define context-scene
    (freeze
     (combine (make-coordinate-reference scene-radius)
              (if (null? edges)
                  empty-pict3d
                  (make-antenna-reference edges scene-radius)))))
  (define (reference-scene)
    (freeze (combine field-map context-scene)))
  (define hit-plane (make-hit-plane section))
  (define phase 0.0)
  (define speed 1.0)
  (define playing? #t)
  (define last-tick (current-inexact-milliseconds))
  (define selected-u #f)
  (define selected-v #f)
  (define selected-center #f)
  (define selected-ellipse #f)
  (define selected-poynting #f)
  (define canvas #f)
  (define u-sample-count
    (length (nec2c-near-field-section-u-values section)))
  (define v-sample-count
    (length (nec2c-near-field-section-v-values section)))
  (define short-interval-count
    (max 1 (sub1 (min u-sample-count v-sample-count))))
  (define minimum-glyph-stride
    (max 1 (inexact->exact (ceiling (/ short-interval-count 24.0)))))
  (define maximum-glyph-stride
    (max minimum-glyph-stride
         (inexact->exact (ceiling (/ short-interval-count 3.0)))))
  (define glyph-stride
    (max minimum-glyph-stride
         (min maximum-glyph-stride
              (inexact->exact (round (/ short-interval-count 10.0))))))
  (define view-mode 'point)
  (define glyph-layout '())
  (define glyph-density-slider #f)
  (define glyph-density-label #f)

  (define frame
    (new frame% [label "Near-field polarization point PoC"]
         [width width] [height height]))
  (define eventspace (current-eventspace))
  (define root (new vertical-panel% [parent frame]))
  (define body (new horizontal-panel% [parent root]))
  (define viewport (new vertical-panel% [parent body]))
  (define rail
    (new vertical-panel% [parent body] [min-width 310]
         [stretchable-width #f] [alignment '(left top)]
         [vert-margin 12] [horiz-margin 12] [spacing 10]))
  (define footer
    (new horizontal-panel% [parent root] [stretchable-height #f]))
  (define status
    (new message% [parent footer]
         [label "drag to orbit  |  wheel to zoom  |  click plane to inspect"]
         [stretchable-width #t]))

  (new message% [parent rail] [label "NEAR-FIELD POLARIZATION"])
  (define field-context-label
    (new message%
       [parent rail]
       [label
        (format "~a plane · ~a-normal at ~a m\n~a MHz · section ~a"
                (string-upcase
                 (symbol->string (nec2c-near-field-section-plane section)))
                (string-upcase
                 (symbol->string
                  (nec2c-near-field-section-normal-axis section)))
                (format-real (nec2c-near-field-section-position section))
                (format-real (nec2c-near-field-result-frequency-mhz result) 5)
                section-index)]
       [stretchable-width #t]))
  (define (update-field-context-label!)
    (send field-context-label set-label
          (case background-quantity
            [(electric)
             (format (string-append
                      "FIELD CONTEXT\n"
                      "magma |E|: ~a dB to p98 ~a V/m\n"
                      "model: cyan (~a wires) · feed: magenta\n"
                      "faint XYZ axes · faint range")
                     (exact-round field-floor-db)
                     (format-real field-peak)
                     (length edges))]
            [(average-power)
             (format (string-append
                      "FIELD CONTEXT\n"
                      "magma |Pavg|: ~a dB to p98 ~a W/m²\n"
                      "model: cyan (~a wires) · feed: magenta\n"
                      "faint XYZ axes · faint range")
                     (exact-round field-floor-db)
                     (format-real field-peak)
                     (length edges))]
            [else
             (format (string-append
                      "FIELD CONTEXT\n"
                      "cyan inward · dark zero · gold outward\n"
                      "signed normal Pavg: ±p98 ~a W/m²\n"
                      "model: cyan (~a wires) · feed: magenta")
                     (format-real field-peak)
                     (length edges))])))
  (update-field-context-label!)
  (define background-selector
    (new radio-box% [parent rail] [label "BACKGROUND"]
         [choices '("|E|" "|PAVG|" "SIGNED NORMAL PAVG")]
         [selection 0]
         [callback
          (lambda (control _event)
            (set! background-quantity
                  (vector-ref #(electric average-power signed-normal-power)
                              (send control get-selection)))
            (define-values (new-map new-peak)
              (make-field-map field scene-radius background-quantity))
            (set! field-map new-map)
            (set! field-peak new-peak)
            (update-field-context-label!)
            (when canvas (send canvas set-reference-grid! (reference-scene))))]))
  (new message%
       [parent rail]
       [label
        (format (string-append
                 "FIELD CONTEXT\n"
                 "magma |E|: ~a dB to p98 ~a V/m\n"
                 "model: cyan (~a wires) · feed: magenta\n"
                 "faint XYZ axes · faint range\n"
                 "orange ghost: Pavg · bright yellow: S(t)")
                (exact-round field-floor-db)
                (format-real field-peak)
                (length edges))]
       [stretchable-width #t])
  (define (glyphs-across-short-side)
    (length
     (near-field-glyph-sample-indices
      (add1 short-interval-count) glyph-stride)))
  (define (update-glyph-density-label!)
    (when glyph-density-label
      (send glyph-density-label set-label
            (format "sample stride ~a · about ~a across short side"
                    glyph-stride (glyphs-across-short-side)))))
  (define (current-glyph-beads)
    (if (eq? view-mode 'ellipses)
        (make-near-field-glyph-beads glyph-layout scene-radius phase)
        empty-pict3d))
  (define (current-selection-trajectory)
    (if (and (eq? view-mode 'point) selected-center)
        (make-trajectory selected-center selected-ellipse scene-radius)
        empty-pict3d))
  (define (current-selection-marker)
    (if (and (eq? view-mode 'point) selected-center)
        (combine (make-marker selected-center scene-radius)
                 (make-origin-guide selected-center scene-radius)
                 (if selected-poynting
                     (make-poynting-arrow selected-center selected-poynting
                                          scene-radius 'average)
                     empty-pict3d))
        empty-pict3d))
  (define (refresh-view-scenes!)
    (when canvas
      (send canvas set-selection-scenes!
            (current-selection-trajectory)
            (current-selection-marker)
            (current-dynamic-scene))))
  (define (rebuild-glyphs!)
    (set! glyph-layout
          (if (eq? view-mode 'point)
              '()
              (make-near-field-glyph-layout field glyph-stride)
              ))
    (when canvas
      (send canvas set-glyph-scenes!
            (case view-mode
              [(ellipses)
               (make-near-field-glyph-rings glyph-layout scene-radius)]
              [(spin)
               (make-near-field-spin-arrows glyph-layout scene-radius)]
              [(power-vectors)
               (make-near-field-power-arrows glyph-layout field scene-radius)]
              [else empty-pict3d])
            (current-glyph-beads))))
  (define glyph-view-selector
    (new radio-box% [parent rail] [label "VIEW"]
         [choices '("POINT + VECTORS" "ELLIPSES" "SPIN" "POWER VECTORS")]
         [selection 0]
         [callback
          (lambda (control _event)
            (set! view-mode
                  (vector-ref #(point ellipses spin power-vectors)
                              (send control get-selection)))
            (send glyph-density-slider enable (not (eq? view-mode 'point)))
            (rebuild-glyphs!)
            ;; These are mutually exclusive views: the grid replaces the
            ;; selected trajectory and both Poynting arrows.  The selection is
            ;; retained so switching back restores it without another click.
            (refresh-view-scenes!))]))
  (set! glyph-density-label
        (new message% [parent rail] [label "sample stride"]
             [auto-resize #t] [stretchable-width #t]))
  (set! glyph-density-slider
        (new slider% [parent rail] [label #f]
             [min-value minimum-glyph-stride]
             [max-value maximum-glyph-stride]
             [init-value glyph-stride]
             [callback
              (lambda (control _event)
                (set! glyph-stride (send control get-value))
                (update-glyph-density-label!)
                (rebuild-glyphs!))]))
  (send glyph-density-slider enable #f)
  (update-glyph-density-label!)
  (new message% [parent rail] [label "SELECTED POINT"])
  (define inspector
    (new message% [parent rail] [label "Click the capture plane."]
         [auto-resize #t] [stretchable-width #t]))
  (new message% [parent rail] [label "RF PHASE"])
  (define phase-label
    (new message% [parent rail] [label "0 degrees"]
         [auto-resize #t] [stretchable-width #t]))
  (define phase-slider #f)
  (define play-button #f)
  (define instantaneous-flow-label #f)

  (define (current-instantaneous-poynting)
    (and selected-center
         (let ([state
                (near-field-flow-sample
                 field selected-u selected-v (degrees->radians phase)
                 'instantaneous)])
           (and state (near-field-flow-state-poynting state)))))

  (define (update-instantaneous-flow-label!)
    (when instantaneous-flow-label
      (define poynting (current-instantaneous-poynting))
      (send instantaneous-flow-label set-label
            (if poynting
                (format "S(t) (~a, ~a, ~a) W/m²\n|S(t)| ~a W/m²"
                        (format-real (first poynting))
                        (format-real (second poynting))
                        (format-real (third poynting))
                        (format-real (vector3-magnitude poynting)))
                "S(t) unavailable"))))

  (define (current-dynamic-scene)
    (if (and (eq? view-mode 'point) selected-center)
        (let ([instantaneous-poynting (current-instantaneous-poynting)])
          (combine
           (make-bead selected-center selected-ellipse scene-radius phase)
           (if instantaneous-poynting
               (make-poynting-arrow selected-center instantaneous-poynting
                                    scene-radius 'instantaneous)
               empty-pict3d)))
        empty-pict3d))

  (define (update-inspector!)
    (define coordinates
      (near-field-plane-point section selected-u selected-v))
    (define electric (near-field-flow-electric field selected-u selected-v))
    (send inspector set-label
          (string-append
           (format "x ~a m\ny ~a m\nz ~a m"
                   (format-real (first coordinates))
                   (format-real (second coordinates))
                   (format-real (third coordinates)))
           (format "\n\nEx ~a V/m\nEy ~a V/m\nEz ~a V/m"
                   (format-complex (first electric))
                   (format-complex (second electric))
                   (format-complex (third electric)))
           (if selected-ellipse
               (let* ([major
                       (near-field-polarization-ellipse-major-amplitude
                        selected-ellipse)]
                      [minor
                       (near-field-polarization-ellipse-minor-amplitude
                        selected-ellipse)])
                 (format "\n\nmajor ~a V/m\nminor ~a V/m\naxial ratio ~a"
                         (format-real major)
                         (format-real minor)
                         (if (> minor (* major 1e-12))
                             (format "~a:1" (format-real (/ major minor) 2))
                             "linear (infinite)")))
               "\n\nfield magnitude is zero")
           (if (and selected-poynting
                    (> (vector3-magnitude selected-poynting) 1e-30))
               (format "\n\nPavg (~a, ~a, ~a) W/m²\n|Pavg| ~a W/m²"
                       (format-real (first selected-poynting))
                       (format-real (second selected-poynting))
                       (format-real (third selected-poynting))
                       (format-real (vector3-magnitude selected-poynting)))
               "\n\nPavg unavailable or zero"))))

  (define (select-hit! hit)
    (set! selected-u
          (axis-coordinate hit (nec2c-near-field-section-u-axis section)))
    (set! selected-v
          (axis-coordinate hit (nec2c-near-field-section-v-axis section)))
    (set! selected-center hit)
    (set! selected-ellipse
          (near-field-polarization-at field selected-u selected-v))
    (define average-state
      (near-field-flow-sample field selected-u selected-v 0.0 'average))
    (set! selected-poynting
          (and average-state (near-field-flow-state-poynting average-state)))
    (update-inspector!)
    (refresh-view-scenes!)
    (update-instantaneous-flow-label!))

  (define (clear-selection!)
    (set! selected-u #f)
    (set! selected-v #f)
    (set! selected-center #f)
    (set! selected-ellipse #f)
    (set! selected-poynting #f)
    (send inspector set-label "Click the capture plane.")
    (when instantaneous-flow-label
      (send instantaneous-flow-label set-label "S(t) unavailable"))
    (send canvas set-selection-scenes!
          empty-pict3d empty-pict3d empty-pict3d))

  (parameterize ([current-pict3d-background (rgba "black")]
                 [current-pict3d-ambient (emitted "white" 1.0)]
                 [current-pict3d-fov view-fov-degrees])
    (set! canvas
          (new near-field-point-canvas%
               [parent viewport] [grid (reference-scene)] [hit-plane hit-plane]
               [center view-center] [radius scene-radius]
               [selection-callback select-hit!]
               [selection-cleared-callback clear-selection!]
               [status-label status])))

  (set! phase-slider
        (new slider% [parent rail] [label #f]
             [min-value 0] [max-value 359] [init-value 0]
             [callback
              (lambda (control _event)
                (set! phase (send control get-value))
                (send phase-label set-label
                      (format "~a degrees" (exact-round phase)))
                (send canvas set-dynamic-scenes!
                      (current-dynamic-scene) (current-glyph-beads))
                (update-instantaneous-flow-label!))]))
  (set! instantaneous-flow-label
        (new message% [parent rail] [label "S(t) unavailable"]
             [auto-resize #t] [stretchable-width #t]))
  (define playback-row
    (new horizontal-panel% [parent rail] [stretchable-height #f]
         [alignment '(left center)]))
  (set! play-button
        (new button% [parent playback-row] [label "PAUSE"]
             [callback
              (lambda (button _event)
                (set! playing? (not playing?))
                (set! last-tick (current-inexact-milliseconds))
                (send button set-label (if playing? "PAUSE" "PLAY")))]))
  (define speed-label
    (new message% [parent playback-row] [label "speed 1.00x"]))
  (new slider% [parent rail] [label #f]
       [min-value 10] [max-value 400] [init-value 100]
       [callback
        (lambda (control _event)
          (set! speed (/ (send control get-value) 100.0))
          (send speed-label set-label
                (format "speed ~ax" (~r speed #:precision 2))))])
  (new message%
       [parent rail]
       [label (string-append
               "The white path is the complete 3D E-field trajectory.\n"
               "Its display size is normalized; amplitudes above are physical.\n"
               "Orange is cycle-average Pavg; yellow is instantaneous S(t).")]
       [stretchable-width #t])

  ;; Start at the exact geometric center so the purpose of the PoC is visible
  ;; immediately, while all later clicks use exact plane intersections.
  (select-hit! view-center)

  (define timer #f)
  (set! timer
        (new timer%
             [interval 33]
             [notify-callback
              (lambda ()
                (cond
                  [(not (send frame is-shown?)) (send timer stop)]
                  [else
                   (define now (current-inexact-milliseconds))
                   (define elapsed (/ (- now last-tick) 1000.0))
                   (set! last-tick now)
                   (when playing?
                     (set! phase
                           (normalize-degrees
                            (+ phase (* phase-degrees-per-second
                                        elapsed speed))))
                     (define displayed (modulo (exact-round phase) 360))
                     (send phase-slider set-value displayed)
                     (send phase-label set-label
                           (format "~a degrees" displayed))
                     (send canvas set-dynamic-scenes!
                           (current-dynamic-scene) (current-glyph-beads))
                     (update-instantaneous-flow-label!))]))]))

  (send frame show #t)
  (make-visualization-handle
   (lambda (new-result)
     (unless (nec2c-near-field-result? new-result)
       (raise-argument-error
        'visualization-update! "nec2c-near-field-result?" new-result))
     (raise-user-error
      'visualization-update!
      "near-field selected-point PoC updates require reopening the viewer"))
   (lambda ()
     (parameterize ([current-eventspace eventspace])
       (queue-callback
        (lambda ()
          (set! last-tick (current-inexact-milliseconds))
          (send frame show #t)
          (send timer start 33)) #f)))
   (lambda ()
     (parameterize ([current-eventspace eventspace])
       (queue-callback (lambda () (send timer stop) (send frame show #f)) #f)))
   (lambda () (send frame is-shown?))))
