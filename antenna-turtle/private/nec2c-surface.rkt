#lang racket/base

(require racket/list
         racket/math
         (prefix-in m: manifold)
         "core.rkt"
         "solid-core.rkt")

(provide
 (struct-out nec2c-surface-patch)
 (struct-out nec2c-surface-attachment)
 (struct-out nec2c-surface-geometry)
 model-nec2c-surface-geometry
 nec2c-adjusted-edge-point)

;; NEC2 does not retain patch corners for its ordinary MFIE calculation, but
;; keeping them here lets the portable report render the reconstructed cells
;; from which centroid, area, and outward normal were derived.
(struct nec2c-surface-patch
  (body-name center normal area corners)
  #:transparent)
(struct nec2c-surface-attachment
  (wire-id end original-point patch-index point normal displacement)
  #:transparent)
(struct nec2c-surface-geometry
  (patches attachments maximum-edge wire-translations)
  #:transparent)

(define (p3->list point)
  (list (m:point3-x point) (m:point3-y point) (m:point3-z point)))

(define (point->list point)
  (list (point3-x point) (point3-y point) (point3-z point)))

(define (list->point values)
  (apply point3 values))

(define (v+ left right) (map + left right))
(define (v- left right) (map - left right))
(define (v* scale vector) (map (lambda (value) (* scale value)) vector))
(define (dot left right) (for/sum ([a (in-list left)] [b (in-list right)]) (* a b)))
(define (cross left right)
  (list (- (* (second left) (third right)) (* (third left) (second right)))
        (- (* (third left) (first right)) (* (first left) (third right)))
        (- (* (first left) (second right)) (* (second left) (first right)))))
(define (norm vector) (sqrt (dot vector vector)))
(define (distance left right) (norm (v- left right)))

(define (linear-part transform) (map (lambda (row) (take row 3)) transform))
(define (translation-part transform) (map fourth transform))

(define (determinant3 matrix)
  (define a (list-ref (first matrix) 0))
  (define b (list-ref (first matrix) 1))
  (define c (list-ref (first matrix) 2))
  (define d (list-ref (second matrix) 0))
  (define e (list-ref (second matrix) 1))
  (define f (list-ref (second matrix) 2))
  (define g (list-ref (third matrix) 0))
  (define h (list-ref (third matrix) 1))
  (define i (list-ref (third matrix) 2))
  (+ (* a (- (* e i) (* f h)))
     (* (- b) (- (* d i) (* f g)))
     (* c (- (* d h) (* e g)))))

(define (inverse3 matrix)
  (define a (list-ref (first matrix) 0))
  (define b (list-ref (first matrix) 1))
  (define c (list-ref (first matrix) 2))
  (define d (list-ref (second matrix) 0))
  (define e (list-ref (second matrix) 1))
  (define f (list-ref (second matrix) 2))
  (define g (list-ref (third matrix) 0))
  (define h (list-ref (third matrix) 1))
  (define i (list-ref (third matrix) 2))
  (define determinant (determinant3 matrix))
  (when (<= (abs determinant) 1e-18)
    (raise-arguments-error
     'model-nec2c-surface-geometry
     "surface-body placement transform is singular"
     "transform" matrix))
  (for/list
      ([row
        (in-list
         (list (list (- (* e i) (* f h)) (- (* c h) (* b i)) (- (* b f) (* c e)))
               (list (- (* f g) (* d i)) (- (* a i) (* c g)) (- (* c d) (* a f)))
               (list (- (* d h) (* e g)) (- (* b g) (* a h)) (- (* a e) (* b d)))) )])
    (map (lambda (value) (/ value determinant)) row)))

(define (matrix-vector matrix vector)
  (for/list ([row (in-list matrix)]) (dot row vector)))

(define (transform-point transform point)
  (v+ (matrix-vector (linear-part transform) point)
      (translation-part transform)))

(define (inverse-transform-point transform point)
  (matrix-vector (inverse3 (linear-part transform))
                 (v- point (translation-part transform))))

(define (body-linear-scale transform)
  (norm (map first (linear-part transform))))

(define (patch-to-world patch transform)
  (define linear (linear-part transform))
  (define scale (body-linear-scale transform))
  (define transformed-normal
    (matrix-vector linear (point->list (nec2c-surface-patch-normal patch))))
  (nec2c-surface-patch
   (nec2c-surface-patch-body-name patch)
   (list->point
    (transform-point transform (point->list (nec2c-surface-patch-center patch))))
   (list->point (v* (/ (norm transformed-normal)) transformed-normal))
   (* (nec2c-surface-patch-area patch) scale scale)
   (for/list ([corner (in-list (nec2c-surface-patch-corners patch))])
     (list->point (transform-point transform (point->list corner))))))

(struct plane-triangle (axis sign coordinate points-2d) #:transparent)

(define (triangle->plane-triangle who body-name points tolerance)
  (define a (first points))
  (define b (second points))
  (define c (third points))
  (define raw-normal (cross (v- b a) (v- c a)))
  (define magnitude (norm raw-normal))
  (when (<= magnitude 1e-18)
    (raise-arguments-error who "Manifold produced a degenerate triangle"
                           "body" body-name "triangle" points))
  (define normal (v* (/ magnitude) raw-normal))
  (define normal-axis
    (for/first ([axis (in-range 3)]
                #:when (>= (abs (list-ref normal axis)) (- 1 tolerance)))
      axis))
  (unless (and normal-axis
               (for/and ([axis (in-range 3)] #:unless (= axis normal-axis))
                 (<= (abs (list-ref normal axis)) tolerance)))
    (raise-arguments-error
     who
     (string-append
      "rev-1 NEC2 surface bodies require every exterior face to be "
      "axis-aligned; build them from translated, unrotated cuboids")
     "body" body-name "triangle" points "normal" normal))
  (define in-plane-axes (remove normal-axis '(0 1 2)))
  (plane-triangle
   normal-axis
   (if (negative? (list-ref normal normal-axis)) -1 1)
   (/ (for/sum ([point (in-list points)])
        (list-ref point normal-axis))
      3)
   (for/list ([point (in-list points)])
     (list (list-ref point (first in-plane-axes))
           (list-ref point (second in-plane-axes))))))

(define (approximately-unique-sorted values tolerance)
  (reverse
   (for/fold ([result '()]) ([value (in-list (sort values <))])
     (if (and (pair? result) (<= (abs (- value (first result))) tolerance))
         result
         (cons value result)))))

(define (subdivide-intervals values maximum-edge)
  (append*
   (for/list ([low (in-list values)] [high (in-list (rest values))]
              #:when (> high low))
     (define count (max 1 (exact-ceiling (/ (- high low) maximum-edge))))
     (define step (/ (- high low) count))
     (for/list ([index (in-range count)])
       (list (+ low (* index step))
             (+ low (* (add1 index) step)))))))

(define (point-in-triangle-2d? point triangle tolerance)
  (define a (first triangle))
  (define b (second triangle))
  (define c (third triangle))
  (define v0 (v- c a))
  (define v1 (v- b a))
  (define v2 (v- point a))
  (define dot00 (dot v0 v0))
  (define dot01 (dot v0 v1))
  (define dot02 (dot v0 v2))
  (define dot11 (dot v1 v1))
  (define dot12 (dot v1 v2))
  (define denominator (- (* dot00 dot11) (* dot01 dot01)))
  (and (> denominator 0)
       (let ([u (/ (- (* dot11 dot02) (* dot01 dot12)) denominator)]
             [v (/ (- (* dot00 dot12) (* dot01 dot02)) denominator)])
         (and (>= u (- tolerance))
              (>= v (- tolerance))
              (<= (+ u v) (+ 1 tolerance))))))

(define (plane-group-patches body-name triangles maximum-edge tolerance)
  (define example (first triangles))
  (define axis (plane-triangle-axis example))
  (define sign (plane-triangle-sign example))
  (define coordinate
    (/ (for/sum ([triangle (in-list triangles)])
         (plane-triangle-coordinate triangle))
       (length triangles)))
  (define in-plane-axes (remove axis '(0 1 2)))
  (define u-values
    (approximately-unique-sorted
     (append*
      (for/list ([triangle (in-list triangles)])
        (map first (plane-triangle-points-2d triangle))))
     tolerance))
  (define v-values
    (approximately-unique-sorted
     (append*
      (for/list ([triangle (in-list triangles)])
        (map second (plane-triangle-points-2d triangle))))
     tolerance))
  (define u-intervals (subdivide-intervals u-values maximum-edge))
  (define v-intervals (subdivide-intervals v-values maximum-edge))
  (define (point3-at u v)
    (define coordinates (make-vector 3 0))
    (vector-set! coordinates axis coordinate)
    (vector-set! coordinates (first in-plane-axes) u)
    (vector-set! coordinates (second in-plane-axes) v)
    (apply point3 (vector->list coordinates)))
  (define normal-coordinates (make-vector 3 0))
  (vector-set! normal-coordinates axis sign)
  (define normal (apply point3 (vector->list normal-coordinates)))
  (for*/list ([u-range (in-list u-intervals)]
              [v-range (in-list v-intervals)]
              #:when
              (let ([midpoint
                     (list (/ (+ (first u-range) (second u-range)) 2)
                           (/ (+ (first v-range) (second v-range)) 2))])
                (for/or ([triangle (in-list triangles)])
                  (point-in-triangle-2d?
                   midpoint (plane-triangle-points-2d triangle) tolerance))))
    (define u0 (first u-range))
    (define u1 (second u-range))
    (define v0 (first v-range))
    (define v1 (second v-range))
    (nec2c-surface-patch
     body-name
     (point3-at (/ (+ u0 u1) 2) (/ (+ v0 v1) 2))
     normal
     (* (- u1 u0) (- v1 v0))
     (list (point3-at u0 v0) (point3-at u1 v0)
           (point3-at u1 v1) (point3-at u0 v1)))))

(define (body-patches body maximum-edge)
  (define mesh (m:solid->mesh (solid-body-solid body)))
  (define vertices (m:mesh-vertices mesh))
  (define placement (solid-body-placement-transform body))
  (define local-maximum-edge (/ maximum-edge (body-linear-scale placement)))
  (define local-vertices
    (for/vector ([point (in-vector vertices)])
      (inverse-transform-point placement (p3->list point))))
  (define scale
    (max 1
         (for*/fold ([maximum 0]) ([point (in-vector local-vertices)]
                                    [value (in-list point)])
           (max maximum (abs value)))))
  (define tolerance (* scale 1e-9))
  (define triangles
    (for/list ([face (in-vector (m:mesh-triangles mesh))])
      (define (vertex index) (vector-ref local-vertices index))
      (triangle->plane-triangle
       'model-nec2c-surface-geometry
       (solid-body-name body)
       (list (vertex (m:triangle-a face))
             (vertex (m:triangle-b face))
             (vertex (m:triangle-c face)))
       tolerance)))
  (define groups (make-hash))
  (for ([triangle (in-list triangles)])
    (define key
      (list (plane-triangle-axis triangle)
            (plane-triangle-sign triangle)
            (round (/ (plane-triangle-coordinate triangle) tolerance))))
    (hash-update! groups key (lambda (values) (cons triangle values)) '()))
  (map
   (lambda (patch) (patch-to-world patch placement))
   (append*
    (for/list ([group (in-hash-values groups)])
      (plane-group-patches
       (solid-body-name body) group local-maximum-edge tolerance)))))

(define (point-in-triangle-3d? point corners tolerance)
  (define a (first corners))
  (define b (second corners))
  (define c (third corners))
  (define p (point->list point))
  (define raw-normal (cross (v- b a) (v- c a)))
  (define normal (v* (/ (norm raw-normal)) raw-normal))
  (and
   (<= (abs (dot (v- p a) normal)) tolerance)
   (let* ([v0 (v- c a)]
          [v1 (v- b a)]
          [v2 (v- p a)]
          [dot00 (dot v0 v0)]
          [dot01 (dot v0 v1)]
          [dot02 (dot v0 v2)]
          [dot11 (dot v1 v1)]
          [dot12 (dot v1 v2)]
          [denominator (- (* dot00 dot11) (* dot01 dot01))])
     (and (> denominator 0)
          (let ([u (/ (- (* dot11 dot02) (* dot01 dot12)) denominator)]
                [v (/ (- (* dot00 dot12) (* dot01 dot02)) denominator)])
            (and (>= u (- tolerance))
                 (>= v (- tolerance))
                 (<= (+ u v) (+ 1 tolerance))))))))

(define (point-in-patch? point patch tolerance)
  (define corners (map point->list (nec2c-surface-patch-corners patch)))
  (or (point-in-triangle-3d? point (take corners 3) tolerance)
      (and (= (length corners) 4)
           (point-in-triangle-3d?
            point (list (first corners) (third corners) (fourth corners))
            tolerance))))

(define (edge-direction edge)
  (v- (point->list (vertex-point (wire-edge-end edge)))
      (point->list (vertex-point (wire-edge-start edge)))))

(define (wire-component-roots edges)
  (define parents (make-hash))
  (define (ensure! id) (hash-ref! parents id (lambda () id)))
  (define (root id)
    (define parent (ensure! id))
    (if (= parent id)
        id
        (let ([result (root parent)])
          (hash-set! parents id result)
          result)))
  (define (join! left right)
    (define left-root (root left))
    (define right-root (root right))
    (unless (= left-root right-root)
      (hash-set! parents right-root left-root)))
  (for ([edge (in-list edges)])
    (join! (vertex-id (wire-edge-start edge))
           (vertex-id (wire-edge-end edge))))
  (for/hash ([edge (in-list edges)])
    (values (wire-edge-id edge)
            (root (vertex-id (wire-edge-start edge))))))

(define (attachment-delta attachment)
  (v- (point->list (nec2c-surface-attachment-point attachment))
      (point->list (nec2c-surface-attachment-original-point attachment))))

(define (component-translations edges attachments tolerance)
  (define roots (wire-component-roots edges))
  (define by-root (make-hash))
  (for ([attachment (in-list attachments)])
    (define root
      (hash-ref roots (nec2c-surface-attachment-wire-id attachment)))
    (hash-update! by-root root
                  (lambda (values) (cons attachment values)) '()))
  (define root-translations
    (for/hash ([(root candidates) (in-hash by-root)])
      (define first-delta (attachment-delta (first candidates)))
      (for ([candidate (in-list (rest candidates))])
        (define candidate-delta (attachment-delta candidate))
        (when (> (distance first-delta candidate-delta) tolerance)
          (raise-arguments-error
           'model-nec2c-surface-geometry
           (string-append
            "one connected wire assembly touches NEC2 surface bodies at "
            "locations requiring incompatible rigid translations")
           "wire ids" (map nec2c-surface-attachment-wire-id candidates)
           "translation vectors" (map attachment-delta candidates))))
      (values root first-delta)))
  (for/hash ([edge (in-list edges)]
             #:when (hash-has-key?
                     root-translations (hash-ref roots (wire-edge-id edge))))
    (values (wire-edge-id edge)
            (hash-ref root-translations
                      (hash-ref roots (wire-edge-id edge))))))

(define (attachment-for endpoint edge end patches tolerance used-indices)
  (define direction (edge-direction edge))
  (define direction-length (norm direction))
  (define candidates
    (for/list ([patch (in-list patches)]
               [index (in-naturals)]
               #:unless (hash-has-key? used-indices index)
               #:when (point-in-patch? endpoint patch tolerance)
               #:when
               (> (/ (abs (dot direction
                              (point->list (nec2c-surface-patch-normal patch))))
                     direction-length)
                  1e-6))
      (cons index patch)))
  (and
   (pair? candidates)
   (let* ([selected
           (argmin
            (lambda (candidate)
              (distance (point->list endpoint)
                        (point->list
                         (nec2c-surface-patch-center (cdr candidate)))))
            candidates)]
          [index (car selected)]
          [patch (cdr selected)]
          [center (nec2c-surface-patch-center patch)])
     (hash-set! used-indices index #t)
     (nec2c-surface-attachment
      (wire-edge-id edge) end endpoint index center
      (nec2c-surface-patch-normal patch)
      (distance (point->list endpoint) (point->list center))))))

(define (model-nec2c-surface-geometry)
  (define maximum-edge (maximum-nec2c-patch-length))
  (define bodies
    (for/list ([body (in-list (model-bodies))]
               #:when (eq? (solid-body-form body) 'surface))
      body))
  (define patches
    (append*
     (for/list ([body (in-list bodies)])
       (unless (eq? (em-material-kind (solid-body-material body)) 'pec)
         (raise-arguments-error
          'model-nec2c-surface-geometry
          "NEC2 surface bodies must be PEC"
          "body" (solid-body-name body)))
       (body-patches body maximum-edge))))
  (define tolerance (max 1e-9 (* maximum-edge 1e-8)))
  (define used-indices (make-hash))
  (define attachments
    (filter
     values
     (append*
      (for/list ([edge (in-list (model-edges))])
        (list
         (attachment-for
          (vertex-point (wire-edge-start edge)) edge 'start
          patches tolerance used-indices)
         (attachment-for
          (vertex-point (wire-edge-end edge)) edge 'end
          patches tolerance used-indices))))))
  (define translations
    (component-translations (model-edges) attachments tolerance))
  (nec2c-surface-geometry patches attachments maximum-edge translations))

(define (nec2c-adjusted-edge-point geometry edge end)
  (define original
    (vertex-point
     ((if (eq? end 'start) wire-edge-start wire-edge-end) edge)))
  (define translation
    (hash-ref (nec2c-surface-geometry-wire-translations geometry)
              (wire-edge-id edge) #f))
  (if translation
      (list->point (v+ (point->list original) translation))
      original))
