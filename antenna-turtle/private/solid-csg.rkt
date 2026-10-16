#lang racket/base

(require racket/list
         (prefix-in m: manifold)
         "core.rkt"
         "material.rkt"
         "solid-core.rkt"
         "solid-placement.rkt"
         "solid-primitives.rkt"
         "stl-import.rkt")

(provide call-with-csg-body
         csg-context-active?
         call-with-csg-operation
         call-with-csg-scale
         add-csg-body
         csg-cuboid
         csg-sphere
         csg-cylinder
         csg-capsule
         csg-stl)

;; A CSG context keeps every temporary primitive in coordinates local to the
;; turtle frame and scale at the entrance to with-body.  The completed solid
;; can consequently travel through add-body's ordinary anchor and placement
;; path exactly once.
(struct csg-context (entry-transform entry-scale) #:transparent)

(define current-csg-context (make-parameter #f))
(define current-csg-collector (make-parameter #f))

(define (csg-context-active?) (and (current-csg-context) #t))

(define (finite-positive who value description)
  (unless (and (real? value) (rational? value) (positive? value))
    (raise-arguments-error
     who (format "~a must be a positive finite real" description)
     description value))
  value)

(define (dimension-list who value count)
  (define values
    (cond
      [(and (list? value) (= (length value) count)) value]
      [(and (vector? value) (= (vector-length value) count))
       (vector->list value)]
      [else
       (raise-argument-error
        who (format "~a-element list or vector" count) value)]))
  (for ([value (in-list values)])
    (finite-positive who value "dimension"))
  values)

(define (matrix-rotation transform)
  (map (lambda (row) (take row 3)) transform))

(define (matrix-translation transform)
  (map fourth transform))

(define (transpose matrix)
  (apply map list matrix))

(define (matrix*matrix left right)
  (define columns (transpose right))
  (for/list ([row (in-list left)])
    (for/list ([column (in-list columns)])
      (for/sum ([a (in-list row)] [b (in-list column)]) (* a b)))))

(define (matrix*vector matrix vector)
  (for/list ([row (in-list matrix)])
    (for/sum ([a (in-list row)] [b (in-list vector)]) (* a b))))

(define (vector- left right)
  (map - left right))

(define (vector-scale vector factor)
  (map (lambda (value) (* value factor)) vector))

(define (context-relative-transform who)
  (define context (current-csg-context))
  (unless context
    (error who "unnamed solid primitives may only be used inside with-body"))
  (define entry (csg-context-entry-transform context))
  (define current (current-turtle-affine-transform who))
  (define entry-inverse-rotation
    (transpose (matrix-rotation entry)))
  (define relative-rotation
    (matrix*matrix entry-inverse-rotation (matrix-rotation current)))
  (define relative-translation
    (vector-scale
     (matrix*vector
      entry-inverse-rotation
      (vector- (matrix-translation current) (matrix-translation entry)))
     (/ (csg-context-entry-scale context))))
  (define relative-scale
    (/ (current-geometry-scale) (csg-context-entry-scale context)))
  (for/list ([row (in-list relative-rotation)]
             [translation (in-list relative-translation)])
    (append (vector-scale row relative-scale) (list translation))))

(define (close-solid! solid)
  (when (and (m:solid? solid) (not (m:solid-closed? solid)))
    (m:solid-close! solid)))

(define (collect-solid! who solid)
  (define collector (current-csg-collector))
  (unless collector
    (close-solid! solid)
    (error who "solid expression may only be used inside with-body"))
  (set-box! collector (cons solid (unbox collector)))
  solid)

(define (place-source! who source anchor)
  (dynamic-wind
    void
    (lambda ()
      (define placement (context-relative-transform who))
      (define anchor-point (solid-anchor-point who source anchor))
      (define effective-placement
        (for/list ([row (in-list placement)])
          (append
           (take row 3)
           (list
            (- (fourth row)
               (for/sum ([coefficient (in-list (take row 3))]
                         [coordinate (in-list anchor-point)])
                 (* coefficient coordinate)))))))
      (collect-solid! who (m:transform source effective-placement)))
    (lambda () (close-solid! source))))

(define (operation-procedure operation)
  (case operation
    [(union) m:union]
    [(difference) m:difference]
    [(intersect) m:intersection]
    [(hull) m:hull]
    [else (error 'with-body "unknown CSG operation ~a" operation)]))

(define (operation-minimum operation)
  (case operation
    [(difference intersect) 2]
    [else 1]))

(define (capture-operation operation thunk)
  (unless (and (procedure? thunk) (procedure-arity-includes? thunk 0))
    (raise-argument-error operation "(procedure-arity-includes/c 0)" thunk))
  (unless (current-csg-context)
    (error operation "CSG operations may only be used inside with-body"))
  (define collected (box '()))
  (with-handlers ([exn?
                   (lambda (failure)
                     (for-each close-solid! (unbox collected))
                     (raise failure))])
    (parameterize ([current-csg-collector collected])
      (call-with-values thunk (lambda _ (void))))
    (define solids (reverse (unbox collected)))
    (unless (>= (length solids) (operation-minimum operation))
      (for-each close-solid! solids)
      (raise-arguments-error
       operation
       (format "expected at least ~a solid expression~a"
               (operation-minimum operation)
               (if (= (operation-minimum operation) 1) "" "s"))
       "received" (length solids)))
    (dynamic-wind
      void
      (lambda () (apply (operation-procedure operation) solids))
      (lambda () (for-each close-solid! solids)))))

(define (call-with-csg-operation operation thunk)
  (collect-solid! operation (capture-operation operation thunk)))

(define (context-current-point)
  (define transform (context-relative-transform 'scale))
  (matrix-translation transform))

(define (call-with-csg-scale factor thunk)
  (finite-positive 'scale factor "scale factor")
  (define source (capture-operation 'union thunk))
  (dynamic-wind
    void
    (lambda ()
      (define center (context-current-point))
      (define translation (vector-scale center (- 1 factor)))
      (define transform
        (for/list ([axis (in-range 3)] [offset (in-list translation)])
          (append
           (for/list ([column (in-range 3)])
             (if (= axis column) factor 0))
           (list offset))))
      (collect-solid! 'scale (m:transform source transform)))
    (lambda () (close-solid! source))))

(define (call-with-csg-body thunk)
  (when (current-csg-context)
    (error 'with-body "with-body contexts may not be nested"))
  (define context
    (csg-context (current-turtle-affine-transform 'with-body)
                 (current-geometry-scale)))
  (call-from-here
   (lambda ()
     (parameterize ([current-csg-context context])
       (capture-operation 'union thunk)))))

(define (add-csg-body name material geometry
                      #:priority [priority #f]
                      #:precedence [precedence #f]
                      #:anchor [anchor 'center]
                      #:metal-thickness [metal-thickness #f]
                      #:form [form 'solid]
                      #:material-source [material-source 'explicit-or-context])
  (dynamic-wind
    void
    (lambda ()
      (add-body name material geometry
                #:priority priority
                #:precedence
                (or precedence
                    (and (not priority)
                         (material-default-precedence material)))
                #:anchor anchor
                #:metal-thickness metal-thickness
                #:form form
                #:material-source material-source))
    (lambda () (close-solid! geometry))))

(define (csg-cuboid size #:anchor [anchor 'center])
  (define dimensions (dimension-list 'cuboid size 3))
  (place-source!
   'cuboid
   (m:cube (first dimensions) (second dimensions) (third dimensions)
           #:center? #t)
   anchor))

(define (csg-sphere radius #:anchor [anchor 'center] #:segments [segments #f])
  (finite-positive 'sphere radius "radius")
  (place-source!
   'sphere
   (if segments (m:sphere radius #:segments segments) (m:sphere radius))
   anchor))

(define (csg-cylinder length diameter
                      #:anchor [anchor 'center]
                      #:segments [segments #f])
  (finite-positive 'cylinder length "length")
  (finite-positive 'cylinder diameter "diameter")
  (place-source!
   'cylinder
   (if segments
       (m:cylinder length (/ diameter 2) #:segments segments #:center? #t)
       (m:cylinder length (/ diameter 2) #:center? #t))
   anchor))

(define (csg-capsule length diameter
                     #:anchor [anchor 'center]
                     #:segments [segments #f])
  (finite-positive 'capsule length "cylindrical length")
  (finite-positive 'capsule diameter "diameter")
  (define start (list 0 0 (- (/ length 2))))
  (define end (list 0 0 (/ length 2)))
  (define effective-anchor
    (case anchor [(start) start] [(end) end] [else anchor]))
  (place-source!
   'capsule
   (if segments
       (m:capsule start end (/ diameter 2) #:segments segments)
       (m:capsule start end (/ diameter 2)))
   effective-anchor))

(define (csg-stl path #:anchor [anchor 'center])
  (place-source! 'stl (read-stl-solid path) anchor))
