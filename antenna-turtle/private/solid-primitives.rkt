#lang racket/base

(require racket/list
         (prefix-in m: manifold)
         "solid-core.rkt")

(provide
 current-solid-material
 call-with-solid-material
 add-cuboid
 add-cuboid/size
 add-solid-sphere
 add-solid-cylinder
 add-solid-capsule
 add-rect-sheet
 add-rect-sheet/size)

;; High-level constructors supply material context without changing the
;; low-level body/sheet API. Materials are immutable and safe to share.
(define current-solid-material (make-parameter pec))

(define (call-with-solid-material material thunk)
  (unless (em-material? material)
    (raise-argument-error 'with-material "em-material?" material))
  (unless (and (procedure? thunk) (procedure-arity-includes? thunk 0))
    (raise-argument-error
     'with-material "(procedure-arity-includes/c 0)" thunk))
  (parameterize ([current-solid-material material]) (thunk)))

(define (positive-finite who value description)
  (unless (and (real? value) (rational? value) (positive? value))
    (raise-arguments-error
     who (format "~a must be a positive finite real" description)
     description value))
  value)

(define (effective-precedence material requested)
  (or requested (material-default-precedence material)))

(define (register-temporary name source material precedence anchor metal-thickness)
  (dynamic-wind
    void
    (lambda ()
      (add-body name material source
                #:precedence (effective-precedence material precedence)
                #:anchor anchor #:metal-thickness metal-thickness))
    (lambda () (unless (m:solid-closed? source) (m:solid-close! source)))))

(define (add-cuboid name length width height
                    #:material [material (current-solid-material)]
                    #:precedence [precedence #f]
                    #:metal-thickness [metal-thickness #f]
                    #:anchor [anchor 'center])
  (positive-finite 'cuboid length "length")
  (positive-finite 'cuboid width "width")
  (positive-finite 'cuboid height "height")
  (register-temporary
   name (m:cube length width height #:center? #t)
   material precedence anchor metal-thickness))

(define (dimension-list who value count)
  (define dimensions
    (cond
      [(and (list? value) (= (length value) count)) value]
      [(and (vector? value) (= (vector-length value) count))
       (vector->list value)]
      [else
       (raise-argument-error
        who (format "~a-element list or vector" count) value)]))
  dimensions)

(define (add-cuboid/size name size
                         #:material [material (current-solid-material)]
                         #:precedence [precedence #f]
                         #:metal-thickness [metal-thickness #f]
                         #:anchor [anchor 'center])
  (define dimensions (dimension-list 'cuboid size 3))
  (add-cuboid name (first dimensions) (second dimensions) (third dimensions)
               #:material material #:precedence precedence
               #:metal-thickness metal-thickness #:anchor anchor))

(define (add-solid-sphere name radius
                          #:material [material (current-solid-material)]
                          #:precedence [precedence #f]
                          #:metal-thickness [metal-thickness #f]
                          #:anchor [anchor 'center]
                          #:segments [segments #f])
  (positive-finite 'sphere radius "radius")
  (define source
    (if segments
        (m:sphere radius #:segments segments)
        (m:sphere radius)))
  (register-temporary name source material precedence anchor metal-thickness))

(define (add-solid-cylinder name length diameter
                            #:material [material (current-solid-material)]
                            #:precedence [precedence #f]
                            #:metal-thickness [metal-thickness #f]
                            #:anchor [anchor 'center]
                            #:segments [segments #f])
  (positive-finite 'cylinder length "length")
  (positive-finite 'cylinder diameter "diameter")
  (define source
    (if segments
        (m:cylinder length (/ diameter 2)
                    #:segments segments #:center? #t)
        (m:cylinder length (/ diameter 2) #:center? #t)))
  (register-temporary name source material precedence anchor metal-thickness))

(define (add-solid-capsule name length diameter
                           #:material [material (current-solid-material)]
                           #:precedence [precedence #f]
                           #:metal-thickness [metal-thickness #f]
                           #:anchor [anchor 'center]
                           #:segments [segments #f])
  (positive-finite 'capsule length "cylindrical length")
  (positive-finite 'capsule diameter "diameter")
  (define start (list 0 0 (- (/ length 2))))
  (define end (list 0 0 (/ length 2)))
  (define source
    (if segments
        (m:capsule start end (/ diameter 2) #:segments segments)
        (m:capsule start end (/ diameter 2))))
  (define effective-anchor
    (case anchor
      [(start) start]
      [(end) end]
      [else anchor]))
  (register-temporary name source material precedence effective-anchor metal-thickness))

(define (add-rect-sheet name length width
                        #:material [material (current-solid-material)]
                        #:precedence [precedence #f]
                        #:thickness [thickness #f]
                        #:mesh-edges [mesh-edges #f])
  (positive-finite 'sheet length "length")
  (positive-finite 'sheet width "width")
  (define half-length (/ length 2))
  (define half-width (/ width 2))
  (add-sheet
   name material
   (list (list (- half-length) (- half-width))
         (list half-length (- half-width))
         (list half-length half-width)
         (list (- half-length) half-width))
   #:precedence (effective-precedence material precedence)
   #:thickness thickness
   #:mesh-edges mesh-edges))

(define (add-rect-sheet/size name size
                             #:material [material (current-solid-material)]
                             #:precedence [precedence #f]
                             #:thickness [thickness #f]
                             #:mesh-edges [mesh-edges #f])
  (define dimensions (dimension-list 'sheet size 2))
  (add-rect-sheet name (first dimensions) (second dimensions)
                  #:material material #:precedence precedence
                  #:thickness thickness
                  #:mesh-edges mesh-edges))
