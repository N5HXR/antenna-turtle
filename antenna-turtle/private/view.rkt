#lang racket/base

(require racket/list
         racket/runtime-path
         plot/no-gui
         "core.rkt"
         "material.rkt"
         "nec2c-dielectric.rkt"
         "plot-cursor.rkt"
         "wire-lumped.rkt"
         "wire-network.rkt")

(provide show-model
         ;; Exposed from this private module for non-GUI tests and future
         ;; tooling. The language itself exports only show-model.
         model->plot-renderers)

(define default-wire-color "steelblue")
(define vertex-color "dark slate gray")
(define feed-color "firebrick")
(define dielectric-color "deep sky blue")
(define lumped-element-color "dark orange")
(define port-negative-color "royal blue")
(define port-positive-color "dark turquoise")

(define-runtime-path proportional-plot3d-path "proportional-plot3d.rkt")

(define (point3->vector point)
  (vector (point3-x point) (point3-y point) (point3-z point)))

(define (edge-points edge)
  (list (point3->vector (vertex-point (wire-edge-start edge)))
        (point3->vector (vertex-point (wire-edge-end edge)))))

(define (feed-point edge)
  (define start (vertex-point (wire-edge-start edge)))
  (define end (vertex-point (wire-edge-end edge)))
  (case (wire-edge-feed-location edge)
    [(start) start]
    [(end) end]
    [(center)
     (point3 (/ (+ (point3-x start) (point3-x end)) 2)
             (/ (+ (point3-y start) (point3-y end)) 2)
             (/ (+ (point3-z start) (point3-z end)) 2))]
    [else #f]))

(define (cuboid-corners cuboid)
  (define-values (minimum maximum) (model-cuboid-bounds cuboid))
  (for*/list ([x (in-list (list (list-ref minimum 0) (list-ref maximum 0)))]
              [y (in-list (list (list-ref minimum 1) (list-ref maximum 1)))]
              [z (in-list (list (list-ref minimum 2) (list-ref maximum 2)))])
    (point3 x y z)))

(define cuboid-edge-indices
  '((0 1) (0 2) (0 4) (1 3) (1 5) (2 3)
    (2 6) (3 7) (4 5) (4 6) (5 7) (6 7)))

(define (dielectric-cuboids)
  (filter (lambda (cuboid)
            (eq? (em-material-kind (model-cuboid-material cuboid)) 'dielectric))
          (model-cuboids)))

(define (cuboid-renderers cuboid)
  (define corners (cuboid-corners cuboid))
  (for/list ([indices (in-list cuboid-edge-indices)])
    (lines3d
     (for/list ([index (in-list indices)])
       (point3->vector (list-ref corners index)))
     #:color dielectric-color
     #:width 1)))

(define (model->plot-renderers [model (current-antenna-model)]
                               #:vertices? [vertices? #f]
                               #:wire-color [wire-color default-wire-color])
  (unless (antenna-model? model)
    (raise-argument-error 'model->plot-renderers "antenna-model?" model))
  (unless (boolean? vertices?)
    (raise-argument-error 'model->plot-renderers "boolean?" vertices?))
  (define edges (model-edges model))
  (when (null? edges)
    (error 'show-model "cannot display an empty model"))
  (define coax-edge-colors (make-hasheq))
  (for ([coax (in-list (model-wire-coaxes))]
        #:when (wire-coax-declaration-color coax))
    (for ([edge (in-list (wire-coax-declaration-shield-edges coax))])
      (hash-set! coax-edge-colors edge (wire-coax-declaration-color coax))))
  (define conductors
    (for/list ([edge (in-list edges)])
      (lines3d (edge-points edge)
               #:color (hash-ref coax-edge-colors edge wire-color)
               #:width 2)))
  (define feeds
    (filter values (map feed-point edges)))
  (define lumped-elements (model-wire-lumped-elements))
  (define ports (model-wire-ports))
  (append
   conductors
   (append-map cuboid-renderers (dielectric-cuboids))
   (if vertices?
       (list
        (points3d
         (for/list ([model-vertex (in-list (model-vertices model))])
           (point3->vector (vertex-point model-vertex)))
         #:color vertex-color
         #:fill-color "white"
         #:line-width 1
         #:size 5
         #:sym 'fullcircle
         #:label "vertices"))
       '())
   (if (null? feeds)
       '()
       (list
        (points3d (map point3->vector feeds)
                  #:color feed-color
                  #:fill-color feed-color
                  #:size 9
                  #:sym 'fullcircle
                  #:label "feed")))
   (if (null? ports)
       '()
       (list
        (points3d
         (map (lambda (port)
                (point3->vector (wire-port-negative-point port)))
              ports)
         #:color port-negative-color
         #:fill-color "white"
         #:line-width 2
         #:size 7
         #:sym 'fullcircle
         #:label "port -")
        (points3d
         (map (lambda (port)
                (point3->vector (wire-port-positive-point port)))
              ports)
         #:color port-positive-color
         #:fill-color port-positive-color
         #:size 7
         #:sym 'fullcircle
         #:label "port +")))
   (if (null? lumped-elements)
       '()
       (list
        (points3d
         (map (lambda (element)
                (point3->vector (wire-lumped-element-center element)))
              lumped-elements)
         #:color lumped-element-color
         #:fill-color "white"
         #:line-width 2
         #:size 9
         #:sym 'diamond
         #:label "lumped element")))))

(define (model-cubic-bounds model)
  ;; Give every coordinate axis the same numeric span. Plot3D otherwise fills
  ;; its plotting cube independently in X, Y, and Z, which can make a flat or
  ;; elongated antenna look deceptively well proportioned.
  (define points
    (append
     (for*/list ([edge (in-list (model-edges model))]
                 [model-vertex
                  (in-list (list (wire-edge-start edge)
                                 (wire-edge-end edge)))])
       (vertex-point model-vertex))
     (append-map cuboid-corners (dielectric-cuboids))))
  (when (null? points)
    (error 'show-model "cannot display an empty model"))
  (define xs (map point3-x points))
  (define ys (map point3-y points))
  (define zs (map point3-z points))
  (define x-center (/ (+ (apply min xs) (apply max xs)) 2))
  (define y-center (/ (+ (apply min ys) (apply max ys)) 2))
  (define z-center (/ (+ (apply min zs) (apply max zs)) 2))
  (define largest-span
    (apply max
           (list (- (apply max xs) (apply min xs))
                 (- (apply max ys) (apply min ys))
                 (- (apply max zs) (apply min zs)))))
  ;; A nonzero wire edge guarantees a positive span, but retaining a fallback
  ;; makes this helper robust against hand-constructed antenna-model values.
  (define half-span (* 11/20 (if (zero? largest-span) 1 largest-span)))
  (values (- x-center half-span) (+ x-center half-span)
          (- y-center half-span) (+ y-center half-span)
          (- z-center half-span) (+ z-center half-span)))

(define (show-model [model (current-antenna-model)]
                    #:vertices? [vertices? #f]
                    #:wire-color [wire-color default-wire-color]
                    #:width [width 900]
                    #:height [height 700]
                    #:aspect-ratio [aspect-ratio 1]
                    #:legend? [legend? #f])
  (unless (antenna-model? model)
    (raise-argument-error 'show-model "antenna-model?" model))
  (unless (exact-positive-integer? width)
    (raise-argument-error 'show-model "exact-positive-integer?" width))
  (unless (exact-positive-integer? height)
    (raise-argument-error 'show-model "exact-positive-integer?" height))
  (unless (and (rational? aspect-ratio) (positive? aspect-ratio))
    (raise-argument-error 'show-model "positive-real?" aspect-ratio))
  (validate-model!)
  (define renderers
    (model->plot-renderers model
                           #:vertices? vertices?
                           #:wire-color wire-color))
  (define-values (x-min x-max y-min y-max z-min z-max)
    (model-cubic-bounds model))
  ;; Loading the GUI backend only here keeps ordinary builds and exports usable
  ;; on machines without a display server.
  (define show-proportional
    (with-handlers ([exn:fail?
                     (lambda (failure)
                       (raise-user-error
                        'show-model
                        "could not start the proportional Plot3D viewer: ~a"
                        (exn-message failure)))])
      (dynamic-require proportional-plot3d-path
                       'show-proportional-plot3d)))
  (show-proportional
   renderers
   #:legend-items
   (append
    (list (plot-legend-item "wire" wire-color 'solid 'line))
    (if vertices?
        (list (plot-legend-item "vertices" vertex-color 'solid 'box))
        '())
    (if (ormap wire-edge-feed-location (model-edges model))
        (list (plot-legend-item "feed" feed-color 'solid 'box))
        '())
    (if (null? (dielectric-cuboids))
        '()
        (list (plot-legend-item "dielectric volume" dielectric-color 'solid 'line)))
    (if (null? (model-wire-lumped-elements))
        '()
        (list (plot-legend-item "lumped element" lumped-element-color 'solid 'box)))
    (if (null? (model-wire-ports))
        '()
        (list (plot-legend-item "port -" port-negative-color 'solid 'box)
              (plot-legend-item "port +" port-positive-color 'solid 'box))))
   #:legend? legend?
   #:title (model-title)
   #:x-label "x (m)"
   #:y-label "y (m)"
   #:z-label "z (m)"
   #:x-min x-min
   #:x-max x-max
   #:y-min y-min
   #:y-max y-max
   #:z-min z-min
   #:z-max z-max
   #:width width
   #:height height
   #:aspect-multiplier aspect-ratio))
