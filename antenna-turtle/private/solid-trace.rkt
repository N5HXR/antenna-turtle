#lang racket/base

(require racket/list
         racket/math
         "core.rkt"
         "solid-core.rkt"
         "solid-primitives.rkt")

(provide call-with-traces)

(define current-trace-active? (make-parameter #f))
(define tolerance 1e-10)

(define (p2 x y) (vector x y))
(define (px p) (vector-ref p 0))
(define (py p) (vector-ref p 1))
(define (p+ a b) (p2 (+ (px a) (px b)) (+ (py a) (py b))))
(define (p- a b) (p2 (- (px a) (px b)) (- (py a) (py b))))
(define (p* a n) (p2 (* (px a) n) (* (py a) n)))
(define (cross2 a b) (- (* (px a) (py b)) (* (py a) (px b))))
(define (length2 a) (sqrt (+ (sqr (px a)) (sqr (py a)))))
(define (unit a)
  (define magnitude (length2 a))
  (when (<= magnitude tolerance)
    (error 'with-traces "trace contains a zero-length segment"))
  (p* a (/ magnitude)))
(define (left-normal direction) (p2 (- (py direction)) (px direction)))
(define (near-number? a b [scale 1])
  (<= (abs (- a b)) (* tolerance (max 1 scale))))
(define (near-p2? a b)
  (and (near-number? (px a) (px b)) (near-number? (py a) (py b))))

(define (point3-list point)
  (list (point3-x point) (point3-y point) (point3-z point)))
(define (dot3 a b) (for/sum ([x (in-list a)] [y (in-list b)]) (* x y)))
(define (minus3 a b) (map - a b))
(define (plus-scaled3 origin u x v y)
  (apply point3
         (for/list ([o (in-list origin)] [a (in-list u)] [b (in-list v)])
           (+ o (* x a) (* y b)))))
(define (column matrix index) (map (lambda (row) (list-ref row index)) matrix))
(define (normalize3 vector)
  (define magnitude (sqrt (dot3 vector vector)))
  (map (lambda (value) (/ value magnitude)) vector))

(define (axis-aligned-normal? normal)
  (= 1 (count (lambda (value) (near-number? (abs value) 1)) normal)))

(define (remove-consecutive-duplicates points)
  (reverse
   (for/fold ([result '()]) ([point (in-list points)])
     (if (and (pair? result) (near-p2? point (car result)))
         result
         (cons point result)))))

(define (simplify-collinear points closed?)
  (define clean (remove-consecutive-duplicates points))
  (define base
    (if (and closed? (near-p2? (first clean) (last clean)))
        (drop-right clean 1)
        clean))
  (if (< (length base) 3)
      base
      (let loop ([remaining base] [result '()])
        (cond
          [(null? remaining) (reverse result)]
          [else
           (define previous (and (pair? result) (car result)))
           (define current (car remaining))
           (define following (and (pair? (cdr remaining)) (cadr remaining)))
           (if (and previous following
                    (near-number? (cross2 (p- current previous)
                                          (p- following current)) 0))
               (loop (cdr remaining) result)
               (loop (cdr remaining) (cons current result)))]))))

(define (orientation a b c) (cross2 (p- b a) (p- c a)))
(define (between? a b c)
  (and (<= (- (min a c) tolerance) b (+ (max a c) tolerance))))
(define (on-segment? a b c)
  (and (near-number? (orientation a b c) 0)
       (between? (px a) (px b) (px c))
       (between? (py a) (py b) (py c))))
(define (segments-intersect? a b c d)
  (define ab-c (orientation a b c))
  (define ab-d (orientation a b d))
  (define cd-a (orientation c d a))
  (define cd-b (orientation c d b))
  (or (and (< (* ab-c ab-d) 0) (< (* cd-a cd-b) 0))
      (on-segment? a c b) (on-segment? a d b)
      (on-segment? c a d) (on-segment? c b d)))

(define (validate-simple-path! points closed?)
  (define segments
    (if closed?
        (for/list ([index (in-range (length points))])
          (list (list-ref points index)
                (list-ref points (modulo (add1 index) (length points)))))
        (for/list ([a (in-list points)] [b (in-list (rest points))])
          (list a b))))
  (for* ([first-index (in-range (length segments))]
         [second-index (in-range (add1 first-index) (length segments))]
         #:unless (or (= second-index (add1 first-index))
                      (and closed? (= first-index 0)
                           (= second-index (sub1 (length segments))))))
    (define first-segment (list-ref segments first-index))
    (define second-segment (list-ref segments second-index))
    (when (segments-intersect? (first first-segment) (second first-segment)
                               (first second-segment) (second second-segment))
      (raise-arguments-error
       'with-traces "self-intersecting traces are not supported"
       "first segment" (add1 first-index)
       "second segment" (add1 second-index)))))

(define (line-intersection p first-direction first-offset
                           second-direction second-offset)
  (define denominator (cross2 first-direction second-direction))
  (when (near-number? denominator 0)
    (if (positive? (for/sum ([a (in-vector first-direction)]
                             [b (in-vector second-direction)]) (* a b)))
        (error 'with-traces "internal collinear trace vertex was not simplified")
        (error 'with-traces "a trace may not reverse direction by 180 degrees")))
  (define first-point
    (p+ p (p* (left-normal first-direction) first-offset)))
  (define second-point
    (p+ p (p* (left-normal second-direction) second-offset)))
  (p+ first-point
      (p* first-direction
          (/ (cross2 (p- second-point first-point) second-direction)
             denominator))))

(define (join-points point previous-direction next-direction side half-width
                     join miter-limit)
  (define first-offset (* side half-width))
  (define first-point
    (p+ point (p* (left-normal previous-direction) first-offset)))
  (define second-point
    (p+ point (p* (left-normal next-direction) first-offset)))
  (define intersection
    (line-intersection point previous-direction first-offset
                       next-direction first-offset))
  (define turn (cross2 previous-direction next-direction))
  (define outer? (< (* side turn) 0))
  (define excessive? (> (/ (length2 (p- intersection point)) half-width)
                         miter-limit))
  (if (and outer? (or (eq? join 'bevel) excessive?))
      (list first-point second-point)
      (list intersection)))

(define (directions points closed?)
  (define pairs
    (if closed?
        (for/list ([index (in-range (length points))])
          (list (list-ref points index)
                (list-ref points (modulo (add1 index) (length points)))))
        (for/list ([a (in-list points)] [b (in-list (rest points))])
          (list a b))))
  (map (lambda (pair) (unit (p- (second pair) (first pair)))) pairs))

(define (open-outline points directions half-width join miter-limit)
  (define first-direction (first directions))
  (define last-direction (last directions))
  (define left-joins
    (append*
     (for/list ([point (in-list (drop-right (rest points) 1))]
                [previous-direction (in-list directions)]
                [next-direction (in-list (rest directions))])
       (join-points point previous-direction next-direction 1 half-width
                    join miter-limit))))
  (define right-joins
    (for/list ([point (in-list (drop-right (rest points) 1))]
               [previous-direction (in-list directions)]
               [next-direction (in-list (rest directions))])
      (join-points point previous-direction next-direction -1 half-width
                   join miter-limit)))
  (append
   (list (p+ (first points) (p* (left-normal first-direction) half-width)))
   left-joins
   (list (p+ (last points) (p* (left-normal last-direction) half-width))
         (p+ (last points) (p* (left-normal last-direction) (- half-width))))
   (append* (map reverse (reverse right-joins)))
   (list (p+ (first points) (p* (left-normal first-direction) (- half-width))))))

;; Triangulate a simple (possibly concave) filled polygon for consumers that
;; cannot directly fill concave faces.  The boundary remains ONE polygon.
;; This is ear clipping, not a convex hull or a triangle fan.
(define (signed-area2 points)
  (for/sum ([a (in-list points)]
            [b (in-list (append (rest points) (list (first points))))])
    (cross2 a b)))

(define (point-in-triangle? p a b c winding)
  ;; Include edges: a candidate ear is invalid if another polygon vertex
  ;; lies inside or on the ear (except the ear's own three vertices).
  (and (>= (* winding (orientation a b p)) (- tolerance))
       (>= (* winding (orientation b c p)) (- tolerance))
       (>= (* winding (orientation c a p)) (- tolerance))))

(define (triangulate-outline outline)
  (define points (remove-consecutive-duplicates outline))
  (define ring
    (if (and (> (length points) 1)
             (near-p2? (first points) (last points)))
        (drop-right points 1)
        points))
  (when (< (length ring) 3)
    (error 'with-traces "trace outline has fewer than three vertices"))
  (define area2 (signed-area2 ring))
  (when (near-number? area2 0)
    (error 'with-traces "trace outline has zero signed area"))
  (define winding (if (positive? area2) 1 -1))
  (let loop ([remaining ring] [triangles '()] [attempts 0])
    (define n (length remaining))
    (cond
      [(= n 3) (reverse (cons remaining triangles))]
      [(> attempts (* (length ring) (length ring)))
       (error 'with-traces
              "could not triangulate the trace outline; check for self-intersecting offsets or overly wide traces")]
      [else
       (define vertices (list->vector remaining))
       (define ear-index
         (for/first ([i (in-range n)]
                     #:when
                     (let* ([a (vector-ref vertices (modulo (sub1 i) n))]
                            [b (vector-ref vertices i)]
                            [c (vector-ref vertices (modulo (add1 i) n))])
                       (and (> (* winding (orientation a b c)) tolerance)
                            (for/and ([j (in-range n)]
                                      #:unless (or (= j i)
                                                   (= j (modulo (sub1 i) n))
                                                   (= j (modulo (add1 i) n))))
                              (not (point-in-triangle?
                                    (vector-ref vertices j) a b c winding))))))
           i))
       (unless ear-index
         (error 'with-traces
                "could not find an ear; trace outline may self-intersect"))
       (define a (vector-ref vertices (modulo (sub1 ear-index) n)))
       (define b (vector-ref vertices ear-index))
       (define c (vector-ref vertices (modulo (add1 ear-index) n)))
       (loop (for/list ([v (in-list remaining)] [i (in-naturals)]
                        #:unless (= i ear-index))
               v)
             (cons (list a b c) triangles)
             (add1 attempts))])))

(define (closed-geometry points directions half-width join miter-limit)
  (define count (length points))
  (define left-joins
    (for/list ([index (in-range count)])
      (join-points (list-ref points index)
                   (list-ref directions (modulo (sub1 index) count))
                   (list-ref directions index)
                   1 half-width join miter-limit)))
  (define right-joins
    (for/list ([index (in-range count)])
      (join-points (list-ref points index)
                   (list-ref directions (modulo (sub1 index) count))
                   (list-ref directions index)
                   -1 half-width join miter-limit)))
  (define polygons
    (append
     (for/list ([index (in-range count)])
       (define point (list-ref points index))
       (define next (list-ref points (modulo (add1 index) count)))
       (define direction (list-ref directions index))
       (define normal (left-normal direction))
       (list (p+ point (p* normal half-width))
             (p+ next (p* normal half-width))
             (p+ next (p* normal (- half-width)))
             (p+ point (p* normal (- half-width)))))
     (for/list ([index (in-range count)])
       (define point (list-ref points index))
       (define previous-direction
         (list-ref directions (modulo (sub1 index) count)))
       (define next-direction (list-ref directions index))
       (remove-consecutive-duplicates
        (append
         (list (p+ point (p* (left-normal previous-direction) half-width)))
         (list-ref left-joins index)
         (list (p+ point (p* (left-normal next-direction) half-width))
               (p+ point (p* (left-normal next-direction) (- half-width))))
         (reverse (list-ref right-joins index))
         (list (p+ point (p* (left-normal previous-direction) (- half-width)))))))))
  (values polygons
          (list (append* left-joins)
                (reverse (append* right-joins)))))

(define (call-with-traces width thunk
                          #:name [name #f]
                          #:material [material (current-solid-material)]
                          #:thickness [thickness #f]
                          #:precedence [precedence #f]
                          #:join [join 'miter]
                          #:miter-limit [miter-limit 4])
  (unless (and (real? width) (rational? width) (positive? width))
    (raise-argument-error 'with-traces "positive finite real width" width))
  (unless (and (procedure? thunk) (procedure-arity-includes? thunk 0))
    (raise-argument-error 'with-traces "zero-argument procedure" thunk))
  (when (current-trace-active?)
    (error 'with-traces "with-traces contexts may not be nested"))
  (when (current-wire-active?)
    (error 'with-traces
           "with-traces may not begin while wire construction is active"))
  (unless (memq join '(miter bevel))
    (raise-argument-error 'with-traces "(or/c 'miter 'bevel)" join))
  (unless (and (real? miter-limit) (rational? miter-limit) (> miter-limit 1))
    (raise-argument-error 'with-traces "finite real greater than 1" miter-limit))
  (define transform (current-turtle-affine-transform 'with-traces))
  (define origin (map last transform))
  (define basis-u (normalize3 (column transform 0)))
  (define basis-v (normalize3 (column transform 1)))
  (define normal (normalize3 (column transform 2)))
  (unless (axis-aligned-normal? normal)
    (error 'with-traces
           "the trace plane must align with the global XY, XZ, or YZ plane"))
  (define effective-width (* width (current-geometry-scale)))
  (define world-points (list (current-position)))
  (define (project point)
    (define offset (minus3 (point3-list point) origin))
    (define distance (dot3 offset normal))
    (when (> (abs distance) (* tolerance (max 1 effective-width)))
      (raise-arguments-error
       'with-traces "movement left the trace plane"
       "off-plane distance" distance "point" point))
    (p2 (dot3 offset basis-u) (dot3 offset basis-v)))
  (define (event-handler event . arguments)
    (case event
      [(move)
       (define destination (second arguments))
       (project destination)
       (unless (equal? destination (last world-points))
         (set! world-points (append world-points (list destination))))]
      [(from-here push pop)
       (error 'with-traces
              "from-here and turtle stack operations would branch or discontinue the trace; use a separate with-traces block")]
      [(with-wire)
       (error 'with-traces
              "wire construction may not be nested inside with-traces")]
      [else (void)]))
  (parameterize ([current-trace-active? #t]
                 [current-turtle-event-handler event-handler])
    (thunk))
  (define projected (remove-consecutive-duplicates (map project world-points)))
  (when (< (length projected) 2)
    (error 'with-traces "at least one nonzero movement is required"))
  (define closed? (and (>= (length projected) 4)
                       (near-p2? (first projected) (last projected))))
  (define points (simplify-collinear projected closed?))
  (when (< (length points) (if closed? 3 2))
    (error 'with-traces "trace path has too few distinct vertices"))
  (validate-simple-path! points closed?)
  (define path-directions (directions points closed?))
  (define half-width (/ effective-width 2))
  (define-values (polygons-2d boundaries-2d)
    (if closed?
        (closed-geometry points path-directions half-width join miter-limit)
        (let ([outline
               (open-outline points path-directions half-width join miter-limit)])
          ;; One authoritative concave outline; triangulation is merely
          ;; the fill representation supplied to add-sheet/world-polygons.
          (values (triangulate-outline outline) (list outline)))))
  (define (world point)
    (plus-scaled3 origin basis-u (px point) basis-v (py point)))
  (add-sheet/world-polygons
   name material
   (map (lambda (polygon) (map world polygon)) polygons-2d)
   (map (lambda (boundary) (map world boundary)) boundaries-2d)
   (apply point3 normal)
   #:precedence precedence #:thickness thickness
   #:mesh-edges 'metal #:trace-width effective-width))
