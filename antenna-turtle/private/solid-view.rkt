#lang racket/base

(require racket/list
         racket/runtime-path
         plot/no-gui
         (prefix-in m: manifold)
         "core.rkt"
         "solid-core.rkt")

(provide show-solid-model
         solid-model->plot-renderers
         solid-model-cubic-bounds)

(define-runtime-path proportional-plot3d-path "proportional-plot3d.rkt")

(define body-colors
  '((pec . "goldenrod")
    (dielectric . "lightblue")
    (conducting-sheet . "silver")))

(define (m-point->vector point)
  (vector (m:point3-x point) (m:point3-y point) (m:point3-z point)))

(define (point->vector point)
  (vector (point3-x point) (point3-y point) (point3-z point)))

(define (mesh-polygons solid)
  (define mesh (m:solid->mesh solid))
  (define vertices (m:mesh-vertices mesh))
  (for/list ([face (in-vector (m:mesh-triangles mesh))])
    (for/list ([index (in-list
                       (list (m:triangle-a face)
                             (m:triangle-b face)
                             (m:triangle-c face)))])
      (m-point->vector (vector-ref vertices index)))))

(define (body-renderer body)
  (define kind (em-material-kind (solid-body-material body)))
  (polygons3d
   (mesh-polygons (solid-body-solid body))
   #:color (cond [(assq kind body-colors) => cdr] [else "lightgray"])
   #:line-color "dimgray"
   #:line-width 0.35
   #:alpha (if (eq? kind 'dielectric) 0.45 0.9)
   #:label (format "~a" (solid-body-name body))))

(define (sheet-renderer sheet)
  (define kind (em-material-kind (planar-sheet-material sheet)))
  (polygons3d
   (list (map point->vector (planar-sheet-points sheet)))
   #:color (cond [(assq kind body-colors) => cdr] [else "silver"])
   #:line-color "gray"
   #:line-width 0.6
   #:alpha 0.9
   #:label (format "~a" (planar-sheet-name sheet))))

(define (point+ point . terms)
  (for/fold ([result point]) ([term (in-list terms)])
    (define vector (car term))
    (define scale (cdr term))
    (point3 (+ (point3-x result) (* scale (point3-x vector)))
            (+ (point3-y result) (* scale (point3-y vector)))
            (+ (point3-z result) (* scale (point3-z vector))))))

(define box-edge-indices
  '((0 1) (0 2) (0 4)
    (1 3) (1 5) (2 3) (2 6)
    (3 7) (4 5) (4 6) (5 7) (6 7)))

(define (port-corners port)
  (define center (lumped-port-center port))
  (define direction (lumped-port-direction port))
  (define u (lumped-port-transverse-u port))
  (define v (lumped-port-transverse-v port))
  (define half-gap (/ (lumped-port-gap port) 2))
  (define half-width (/ (lumped-port-width port) 2))
  (define half-depth (/ (lumped-port-depth port) 2))
  (for*/list ([direction-sign (in-list '(-1 1))]
              [u-sign (in-list '(-1 1))]
              [v-sign (in-list '(-1 1))])
    (point+ center
            (cons direction (* direction-sign half-gap))
            (cons u (* u-sign half-width))
            (cons v (* v-sign half-depth)))))

(define (port-renderers port)
  (define corners (port-corners port))
  (define center (lumped-port-center port))
  (define tip
    (point+ center
            (cons (lumped-port-direction port)
                  (max (lumped-port-gap port)
                       (lumped-port-width port)
                       (lumped-port-depth port)))))
  (append
   (for/list ([edge (in-list box-edge-indices)] [index (in-naturals)])
     (lines3d
      (for/list ([corner-index (in-list edge)])
        (point->vector (list-ref corners corner-index)))
      #:color "firebrick"
      #:width 2
      #:label (and (zero? index)
                   (format "port: ~a" (lumped-port-name port)))))
   (list
    (lines3d (list (point->vector center) (point->vector tip))
             #:color "red" #:width 4)
    (points3d (list (point->vector tip))
              #:color "red" #:fill-color "red"
              #:size 7 #:sym 'fulltriangle))))

(define (solid-model->plot-renderers)
  (validate-solid-scene!)
  (when (and (null? (model-bodies)) (null? (model-sheets)))
    (error 'show-solid-model "cannot display a scene without bodies or sheets"))
  (append
   (map body-renderer (model-bodies))
   (map sheet-renderer (model-sheets))
   (append* (map port-renderers (model-ports)))))

(define (solid-model-cubic-bounds)
  (define extrema
    (append*
     (append
      (for/list ([body (in-list (model-bodies))])
        (define-values (minimum maximum)
          (m:solid-bounds (solid-body-solid body)))
        (list (m-point->vector minimum) (m-point->vector maximum)))
      (for/list ([sheet (in-list (model-sheets))])
        (map point->vector (planar-sheet-points sheet)))
      (for/list ([port (in-list (model-ports))])
        (map point->vector (port-corners port))))))
  (define (coordinate index) (map (lambda (point) (vector-ref point index)) extrema))
  (define mins (for/list ([index (in-range 3)]) (apply min (coordinate index))))
  (define maxs (for/list ([index (in-range 3)]) (apply max (coordinate index))))
  (define centers (map (lambda (low high) (/ (+ low high) 2)) mins maxs))
  (define largest-span
    (apply max (map (lambda (low high) (- high low)) mins maxs)))
  (define half-span (* 0.55 (if (zero? largest-span) 1 largest-span)))
  (apply values
         (append*
          (for/list ([center (in-list centers)])
            (list (- center half-span) (+ center half-span))))))

(define (show-solid-model #:width [width 900]
                          #:height [height 700]
                          #:aspect-ratio [aspect-ratio 1])
  (unless (exact-positive-integer? width)
    (raise-argument-error 'show-solid-model "exact-positive-integer?" width))
  (unless (exact-positive-integer? height)
    (raise-argument-error 'show-solid-model "exact-positive-integer?" height))
  (unless (and (rational? aspect-ratio) (positive? aspect-ratio))
    (raise-argument-error 'show-solid-model "positive-real?" aspect-ratio))
  (define renderers (solid-model->plot-renderers))
  (define-values (x-min x-max y-min y-max z-min z-max)
    (solid-model-cubic-bounds))
  (define show-proportional
    (with-handlers ([exn:fail?
                     (lambda (failure)
                       (raise-user-error
                        'show-solid-model
                        "could not start the proportional Plot3D viewer: ~a"
                        (exn-message failure)))])
      (dynamic-require proportional-plot3d-path 'show-proportional-plot3d)))
  ;; Do not inherit ambient Plot theme parameters from earlier live-coding
  ;; expressions; a deterministic light canvas keeps every material visible.
  (parameterize ([plot-background "white"]
                 [plot-foreground "black"])
    (show-proportional
     renderers
     #:title (format "~a — solid model" (model-title))
     #:x-label "x (m)" #:y-label "y (m)" #:z-label "z (m)"
     #:x-min x-min #:x-max x-max
     #:y-min y-min #:y-max y-max
     #:z-min z-min #:z-max z-max
     #:width width #:height height
     #:aspect-multiplier aspect-ratio)))
