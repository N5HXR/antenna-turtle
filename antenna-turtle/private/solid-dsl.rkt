#lang racket

(require (except-in "core.rkt" cylinder)
         (only-in "core.rkt" [cylinder turtle-cylinder-warp])
         (except-in "solid-core.rkt" dielectric conductor)
         (only-in "material.rkt" make-conductor)
         "solid-primitives.rkt"
         "stl-import.rkt"
         (for-syntax racket/base racket/list syntax/parse))

(provide body sheet port lumped-element dielectric conductor with-material mesh-plane
         cuboid sphere cylinder capsule stl read-stl-solid)

(begin-for-syntax
  (define (settings who stx items allowed description)
    (define values (syntax->list items))
    (when (odd? (length values))
      (raise-syntax-error who description stx))
    (define result (make-hasheq))
    (for ([offset (in-range 0 (length values) 2)])
      (define key-stx (list-ref values offset))
      (unless (identifier? key-stx)
        (raise-syntax-error who "expected a contextual setting name" stx key-stx))
      (define key (syntax-e key-stx))
      (unless (memq key allowed)
        (raise-syntax-error who description stx key-stx))
      (when (hash-has-key? result key)
        (raise-syntax-error who "setting may be specified only once" stx key-stx))
      (hash-set! result key (list-ref values (add1 offset))))
    result)

  (define (literal-expression value allowed who stx description [default #f])
    (cond
      [(not value) default]
      [(and (identifier? value) (memq (syntax-e value) allowed))
       #`'#,(syntax-e value)]
      [else
       (raise-syntax-error who description stx value)]))

  (define (name-expression value)
    (if (identifier? value) #`'#,(syntax-e value) value))

  (define (optional-keyword settings key keyword)
    (if (hash-has-key? settings key)
        (list keyword (hash-ref settings key))
        '()))

  (define (precedence-keywords settings)
    (append (optional-keyword settings 'priority #'#:priority)
            (optional-keyword settings 'precedence #'#:precedence)))

  (define (material-keywords settings)
    (optional-keyword settings 'material #'#:material))

  (define (anchor-keywords settings [default #f])
    (cond
      [(hash-has-key? settings 'anchor)
       (define value (hash-ref settings 'anchor))
       (list #'#:anchor
             (if (identifier? value) #`'#,(syntax-e value) value))]
      [default (list #'#:anchor default)]
      [else '()]))

  (define valid-directions
    '(forward forwards back backward backwards left right up down)))

(define-syntax-rule (with-material material body ...)
  (call-with-solid-material material (lambda () body ...)))

(define-syntax (mesh-plane stx)
  (syntax-parse stx
    [(_ plane:id)
     (unless (memq (syntax-e #'plane) '(xy xz yz))
       (raise-syntax-error 'mesh-plane "expected xy, xz, or yz" stx #'plane))
     #`(add-mesh-plane '#,(syntax-e #'plane))]
    [(_ . _)
     (raise-syntax-error 'mesh-plane "expected (mesh-plane xy|xz|yz)" stx)]))

;; Accept both the existing keyword constructor and the concise material DSL.
(define-syntax (dielectric stx)
  (syntax-parse stx
    [(_ argument ...)
     (define arguments (syntax->list #'(argument ...)))
     (if (ormap keyword? (map syntax-e arguments))
         #'(make-dielectric argument ...)
         (let* ([values
                 (settings
                  'dielectric stx #'(argument ...)
                  '(name er ur relative-permittivity relative-permeability
                         loss-tangent loss-frequency conductivity)
                  (string-append
                   "expected name, er, ur, relative-permittivity, or "
                   "relative-permeability, loss-tangent, loss-frequency, or "
                   "conductivity setting/value pairs"))]
                [epsilon
                 (or (hash-ref values 'er #f)
                     (hash-ref values 'relative-permittivity #f))]
                [mu
                 (or (hash-ref values 'ur #f)
                     (hash-ref values 'relative-permeability #'1))]
                [name (hash-ref values 'name #''dielectric)])
           (unless epsilon
             (raise-syntax-error
              'dielectric "er or relative-permittivity is required" stx))
           #`(make-dielectric
              #:name #,(name-expression name)
              #:relative-permittivity #,epsilon
              #:relative-permeability #,mu
              #,@(optional-keyword values 'loss-tangent #'#:loss-tangent)
              #,@(optional-keyword values 'loss-frequency #'#:loss-frequency)
              #,@(optional-keyword values 'conductivity #'#:conductivity))))]))

(define-syntax (conductor stx)
  (syntax-parse stx
    [(_ argument ...)
     (define arguments (syntax->list #'(argument ...)))
     (if (ormap keyword? (map syntax-e arguments))
         #'(make-conductor argument ...)
         (let ([values
                (settings 'conductor stx #'(argument ...)
                          '(name conductivity)
                          "expected name or conductivity setting/value pairs")])
           (define conductivity (hash-ref values 'conductivity #f))
           (unless conductivity
             (raise-syntax-error 'conductor "conductivity is required" stx))
           (define name (hash-ref values 'name #''conductor))
           #`(make-conductor #:name #,(name-expression name)
                            #:conductivity #,conductivity)))]))

(define-syntax (body stx)
  (syntax-parse stx
    [(_ name:id setting ...)
     (define values
       (settings 'body stx #'(setting ...)
                 '(geometry material priority precedence coordinates anchor
                            metal-thickness)
                 (string-append
                  "expected geometry, material, priority, precedence, "
                  "coordinates, anchor, or metal-thickness setting/value pairs")))
     (define geometry (hash-ref values 'geometry #f))
     (unless geometry
       (raise-syntax-error 'body "geometry setting is required" stx))
     (define material
       (hash-ref values 'material #'(current-solid-material)))
     (define coordinates
       (literal-expression
        (hash-ref values 'coordinates #f) '(local world) 'body stx
        "coordinates must be local or world" #''local))
     #`(add-body '#,(syntax-e #'name) #,material #,geometry
                 #:coordinates #,coordinates
                 #,@(optional-keyword values 'metal-thickness #'#:metal-thickness)
                 #,@(precedence-keywords values)
                 #,@(anchor-keywords values))]
    [(_ . _)
     (raise-syntax-error 'body "expected (body NAME setting value ...)" stx)]))

(define-syntax (sheet stx)
  (syntax-parse stx
    [(_ (~datum rect) name:id setting ...)
     (define values
       (settings 'sheet stx #'(setting ...)
                 '(size length width material precedence mesh-edges thickness)
                 (string-append
                  "expected size, length, width, material, "
                  "precedence, thickness, or mesh-edges setting/value pairs")))
     (define size (hash-ref values 'size #f))
     (define length (hash-ref values 'length #f))
     (define width (hash-ref values 'width #f))
     (when (and size (or length width))
       (raise-syntax-error 'sheet "use either size or length/width" stx))
     (unless (or size (and length width))
       (raise-syntax-error 'sheet "size or both length and width are required" stx))
     (define mesh
       (literal-expression
        (hash-ref values 'mesh-edges #f) '(exact metal) 'sheet stx
        "mesh-edges must be exact or metal" #''exact))
     ;; Rebuild the call so optional keywords follow the positional arguments.
     (if size
         #`(add-rect-sheet/size
            '#,(syntax-e #'name) #,size
            #,@(material-keywords values)
            #,@(optional-keyword values 'precedence #'#:precedence)
            #,@(optional-keyword values 'thickness #'#:thickness)
            #:mesh-edges #,mesh)
         #`(add-rect-sheet
            '#,(syntax-e #'name) #,length #,width
            #,@(material-keywords values)
            #,@(optional-keyword values 'precedence #'#:precedence)
            #,@(optional-keyword values 'thickness #'#:thickness)
            #:mesh-edges #,mesh))]
    [(_ name:id setting ...)
     (define values
       (settings 'sheet stx #'(setting ...)
                 '(points material priority precedence coordinates mesh-edges thickness)
                 (string-append
                  "expected points, material, priority, precedence, "
                  "coordinates, or mesh-edges setting/value pairs")))
     (define points (hash-ref values 'points #f))
     (unless points (raise-syntax-error 'sheet "points setting is required" stx))
     (define material
       (hash-ref values 'material #'(current-solid-material)))
     (define coordinates
       (literal-expression
        (hash-ref values 'coordinates #f) '(local world) 'sheet stx
        "coordinates must be local or world" #''local))
     (define mesh
       (literal-expression
        (hash-ref values 'mesh-edges #f) '(exact metal) 'sheet stx
        "mesh-edges must be exact or metal" #''exact))
     #`(add-sheet '#,(syntax-e #'name) #,material #,points
                  #:coordinates #,coordinates #:mesh-edges #,mesh
                  #,@(optional-keyword values 'thickness #'#:thickness)
                  #,@(precedence-keywords values))]
    [(_ . _)
     (raise-syntax-error 'sheet "expected a named sheet" stx)]))

(define-syntax (port stx)
  (syntax-parse stx
    [(_ direction:id setting ...)
     (unless (memq (syntax-e #'direction) valid-directions)
       (raise-syntax-error 'port "expected a turtle direction" stx #'direction))
     (define values
       (settings 'port stx #'(setting ...)
                 '(name impedance gap width depth size priority precedence)
                 (string-append
                  "expected name, impedance, gap, width, depth, size, "
                  "priority, or precedence setting/value pairs")))
     (when (and (hash-has-key? values 'size)
                (or (hash-has-key? values 'width)
                    (hash-has-key? values 'depth)))
       (raise-syntax-error 'port "use either size or width/depth" stx))
     (define keyword-arguments
       (append
        (if (hash-has-key? values 'name)
            (list #'#:name (name-expression (hash-ref values 'name))) '())
        (optional-keyword values 'impedance #'#:impedance)
        (optional-keyword values 'gap #'#:gap)
        (optional-keyword values 'width #'#:width)
        (optional-keyword values 'depth #'#:depth)
        (precedence-keywords values)))
     (if (hash-has-key? values 'size)
         (let ([size (hash-ref values 'size)])
           #`(let ([dimensions #,size])
               (unless (and (list? dimensions) (= (length dimensions) 2))
                 (raise-argument-error 'port "two-element size list" dimensions))
               (add-lumped-port
                '#,(syntax-e #'direction)
                #:width (first dimensions) #:depth (second dimensions)
                #,@keyword-arguments)))
         #`(add-lumped-port '#,(syntax-e #'direction) #,@keyword-arguments))]
    [(_ . _)
     (raise-syntax-error 'port "expected (port DIRECTION setting value ...)" stx)]))

(define-syntax (lumped-element stx)
  (syntax-parse stx
    [(_ direction:id setting ...)
     (unless (memq (syntax-e #'direction) valid-directions)
       (raise-syntax-error 'lumped-element
                           "expected a turtle direction" stx #'direction))
     (define values
       (settings
        'lumped-element stx #'(setting ...)
        '(name resistance inductance capacitance topology caps
               gap width depth size priority precedence)
        (string-append
         "expected name, resistance, inductance, capacitance, topology, caps, "
         "gap, width, depth, size, priority, or precedence setting/value pairs")))
     (unless (hash-has-key? values 'name)
       (raise-syntax-error 'lumped-element "name setting is required" stx))
     (unless (hash-has-key? values 'gap)
       (raise-syntax-error 'lumped-element "gap setting is required" stx))
     (unless (ormap (lambda (key) (hash-has-key? values key))
                    '(resistance inductance capacitance))
       (raise-syntax-error 'lumped-element
                           "an electrical value is required" stx))
     (when (and (hash-has-key? values 'size)
                (or (hash-has-key? values 'width)
                    (hash-has-key? values 'depth)))
       (raise-syntax-error 'lumped-element
                           "use either size or width/depth" stx))
     (unless (or (hash-has-key? values 'size)
                 (and (hash-has-key? values 'width)
                      (hash-has-key? values 'depth)))
       (raise-syntax-error 'lumped-element
                           "size or both width and depth are required" stx))
     (define topology
       (and (hash-has-key? values 'topology)
            (literal-expression
             (hash-ref values 'topology) '(series parallel)
             'lumped-element stx "topology must be series or parallel")))
     (define common
       (append
        (list #'#:name (name-expression (hash-ref values 'name))
              #'#:gap (hash-ref values 'gap))
        (optional-keyword values 'resistance #'#:resistance)
        (optional-keyword values 'inductance #'#:inductance)
        (optional-keyword values 'capacitance #'#:capacitance)
        (if topology (list #'#:topology topology) '())
        (optional-keyword values 'caps #'#:caps)
        (precedence-keywords values)))
     (if (hash-has-key? values 'size)
         (let ([size (hash-ref values 'size)])
           #`(let ([dimensions #,size])
               (unless (and (list? dimensions) (= (length dimensions) 2))
                 (raise-argument-error
                  'lumped-element "two-element size list" dimensions))
               (add-lumped-element
                '#,(syntax-e #'direction)
                #:width (first dimensions) #:depth (second dimensions)
                #,@common)))
         #`(add-lumped-element
            '#,(syntax-e #'direction)
            #:width #,(hash-ref values 'width)
            #:depth #,(hash-ref values 'depth)
            #,@common))]
    [(_ . _)
     (raise-syntax-error
      'lumped-element
      "expected (lumped-element DIRECTION setting value ...)" stx)]))

(define-syntax (cuboid stx)
  (syntax-parse stx
    [(_ name:id setting ...)
     (define values
       (settings 'cuboid stx #'(setting ...)
                 '(size length width height material precedence anchor metal-thickness)
                 (string-append
                  "expected size, length, width, height, material, "
                  "precedence, or anchor setting/value pairs")))
     (define size (hash-ref values 'size #f))
     (define length (hash-ref values 'length #f))
     (define width (hash-ref values 'width #f))
     (define height (hash-ref values 'height #f))
     (when (and size (or length width height))
       (raise-syntax-error 'cuboid "use either size or named dimensions" stx))
     (unless (or size (and length width height))
       (raise-syntax-error
        'cuboid "size or length, width, and height are required" stx))
     (if size
         #`(add-cuboid/size
            '#,(syntax-e #'name) #,size
            #,@(material-keywords values)
            #,@(optional-keyword values 'precedence #'#:precedence)
            #,@(optional-keyword values 'metal-thickness #'#:metal-thickness)
            #,@(anchor-keywords values #''center))
         #`(add-cuboid
            '#,(syntax-e #'name) #,length #,width #,height
            #,@(material-keywords values)
            #,@(optional-keyword values 'precedence #'#:precedence)
            #,@(optional-keyword values 'metal-thickness #'#:metal-thickness)
            #,@(anchor-keywords values #''center)))]))

(define-syntax (sphere stx)
  (syntax-parse stx
    [(_ name:id setting ...)
     (define values
       (settings 'sphere stx #'(setting ...)
                 '(radius diameter material precedence anchor segments metal-thickness)
                 (string-append
                  "expected radius, diameter, material, precedence, anchor, "
                  "or segments setting/value pairs")))
     (define radius (hash-ref values 'radius #f))
     (define diameter (hash-ref values 'diameter #f))
     (unless (or (and radius (not diameter)) (and diameter (not radius)))
       (raise-syntax-error 'sphere "specify exactly one of radius or diameter" stx))
     #`(add-solid-sphere
        '#,(syntax-e #'name) #,(or radius #`(/ #,diameter 2))
        #,@(material-keywords values)
        #,@(optional-keyword values 'precedence #'#:precedence)
        #,@(optional-keyword values 'metal-thickness #'#:metal-thickness)
        #,@(anchor-keywords values #''center)
        #,@(optional-keyword values 'segments #'#:segments))]))

(define-for-syntax (axial-solid-call who target stx name settings-stx)
  (define values
    (settings who stx settings-stx
              '(length diameter radius material precedence anchor segments metal-thickness)
              (format "expected dimensions and ~a construction settings" who)))
  (define length (hash-ref values 'length #f))
  (define diameter (hash-ref values 'diameter #f))
  (define radius (hash-ref values 'radius #f))
  (unless length (raise-syntax-error who "length is required" stx))
  (unless (or (and diameter (not radius)) (and radius (not diameter)))
    (raise-syntax-error who "specify exactly one of diameter or radius" stx))
  #`(#,target
     '#,(syntax-e name) #,length #,(or diameter #`(* 2 #,radius))
     #,@(material-keywords values)
     #,@(optional-keyword values 'precedence #'#:precedence)
     #,@(optional-keyword values 'metal-thickness #'#:metal-thickness)
     #,@(anchor-keywords values #''center)
     #,@(optional-keyword values 'segments #'#:segments)))

(define-syntax (cylinder stx)
  (syntax-parse stx
    [(_ radius:expr) #'(turtle-cylinder-warp radius)]
    [(_ name:id setting ...)
     (axial-solid-call
      'cylinder #'add-solid-cylinder stx #'name #'(setting ...))]))

(define-syntax (capsule stx)
  (syntax-parse stx
    [(_ name:id setting ...)
     (axial-solid-call
      'capsule #'add-solid-capsule stx #'name #'(setting ...))]))

(define-syntax (stl stx)
  (syntax-parse stx
    [(_ name:id setting ...)
     (define values
       (settings 'stl stx #'(setting ...)
                 '(path material precedence anchor)
                 "expected path, material, precedence, or anchor setting/value pairs"))
     (define path (hash-ref values 'path #f))
     (unless path (raise-syntax-error 'stl "path is required" stx))
     #`(add-stl-body
        '#,(syntax-e #'name) #,path
        #,@(material-keywords values)
        #,@(optional-keyword values 'precedence #'#:precedence)
        #,@(anchor-keywords values #''center))]))
