#lang racket

(require (except-in "core.rkt" cylinder scale)
         (only-in "core.rkt" [cylinder turtle-cylinder-warp])
         (except-in "solid-core.rkt" dielectric conductor)
         (only-in "material.rkt" make-conductor)
         "solid-primitives.rkt"
         "solid-csg.rkt"
         "solid-csg-dsl.rkt"
         "stl-import.rkt"
         (for-syntax racket/base racket/list syntax/parse))

(provide body sheet port lumped-element dielectric conductor with-material mesh-plane
         (all-from-out "solid-csg-dsl.rkt")
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

  (define (scene-only-settings? settings)
    (ormap (lambda (key) (hash-has-key? settings key))
           '(name material precedence metal-thickness)))

  (define (requested-name-expression settings)
    (if (hash-has-key? settings 'name)
        (name-expression (hash-ref settings 'name))
        #'#f))

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
    [(_ old-name:id setting ...)
     #:when (not (memq (syntax-e #'old-name)
                       '(name geometry material priority precedence coordinates
                              anchor metal-thickness)))
     (raise-syntax-error
      'body "positional names are not supported; use name VALUE" stx #'old-name)]
    [(_ setting ...)
     (define values
       (settings 'body stx #'(setting ...)
                 '(name geometry material priority precedence coordinates
                        anchor metal-thickness)
                 "expected body setting/value pairs"))
     (define geometry (hash-ref values 'geometry #f))
     (unless geometry
       (raise-syntax-error 'body "geometry setting is required" stx))
     (define material (hash-ref values 'material #'(current-solid-material)))
     (define coordinates
       (literal-expression
        (hash-ref values 'coordinates #f) '(local world) 'body stx
        "coordinates must be local or world" #''local))
     #`(add-body #,(if (hash-has-key? values 'name)
                       (name-expression (hash-ref values 'name))
                       #'#f)
                 #,material #,geometry
                 #:coordinates #,coordinates
                 #,@(optional-keyword values 'metal-thickness #'#:metal-thickness)
                 #,@(precedence-keywords values)
                 #,@(anchor-keywords values))]
    [(_ . _)
     (raise-syntax-error
      'body "expected (body [name value] setting value ...)" stx)]))

(define-syntax (sheet stx)
  (syntax-parse stx
    [(_ (~datum rect) old-name:id setting ...)
     #:when (not (memq (syntax-e #'old-name)
                       '(name size length width material priority precedence
                              mesh-edges thickness)))
     (raise-syntax-error
      'sheet "positional names are not supported; use name VALUE" stx #'old-name)]
    [(_ (~datum rect) setting ...)
     (define values
       (settings 'sheet stx #'(setting ...)
                 '(name size length width material priority precedence
                        mesh-edges thickness)
                 "expected sheet setting/value pairs"))
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
     (define requested-name
       (if (hash-has-key? values 'name)
           (name-expression (hash-ref values 'name))
           #'#f))
     (if size
         #`(add-rect-sheet/size
            #,requested-name #,size
            #,@(material-keywords values)
            #,@(precedence-keywords values)
            #,@(optional-keyword values 'thickness #'#:thickness)
            #:mesh-edges #,mesh)
         #`(add-rect-sheet
            #,requested-name #,length #,width
            #,@(material-keywords values)
            #,@(precedence-keywords values)
            #,@(optional-keyword values 'thickness #'#:thickness)
            #:mesh-edges #,mesh))]
    [(_ old-name:id setting ...)
     #:when (not (memq (syntax-e #'old-name)
                       '(name points material priority precedence coordinates
                              mesh-edges thickness)))
     (raise-syntax-error
      'sheet "positional names are not supported; use name VALUE" stx #'old-name)]
    [(_ setting ...)
     (define values
       (settings 'sheet stx #'(setting ...)
                 '(name points material priority precedence coordinates
                        mesh-edges thickness)
                 "expected sheet setting/value pairs"))
     (define points (hash-ref values 'points #f))
     (unless points (raise-syntax-error 'sheet "points setting is required" stx))
     (define material (hash-ref values 'material #'(current-solid-material)))
     (define coordinates
       (literal-expression
        (hash-ref values 'coordinates #f) '(local world) 'sheet stx
        "coordinates must be local or world" #''local))
     (define mesh
       (literal-expression
        (hash-ref values 'mesh-edges #f) '(exact metal) 'sheet stx
        "mesh-edges must be exact or metal" #''exact))
     #`(add-sheet #,(if (hash-has-key? values 'name)
                        (name-expression (hash-ref values 'name))
                        #'#f)
                  #,material #,points
                  #:coordinates #,coordinates #:mesh-edges #,mesh
                  #,@(optional-keyword values 'thickness #'#:thickness)
                  #,@(precedence-keywords values))]
    [(_ . _)
     (raise-syntax-error
      'sheet "expected (sheet [rect] [name value] setting value ...)" stx)]))

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
        (append
         (if (hash-has-key? values 'name)
             (list #'#:name (name-expression (hash-ref values 'name)))
             '())
         (list #'#:gap (hash-ref values 'gap)))
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
    [(_ old-name:id setting ...)
     #:when (not (memq (syntax-e #'old-name)
                       '(name size length width height material precedence
                              anchor metal-thickness)))
     (raise-syntax-error
      'cuboid "positional names are not supported; use name VALUE" stx #'old-name)]
    [(_ setting ...)
     (define values
       (settings 'cuboid stx #'(setting ...)
                 '(name size length width height material precedence anchor
                        metal-thickness)
                 (string-append
                  "expected dimensions, material, precedence, anchor, or "
                  "metal-thickness "
                  "setting/value pairs")))
     (define size (hash-ref values 'size #f))
     (define length (hash-ref values 'length #f))
     (define width (hash-ref values 'width #f))
     (define height (hash-ref values 'height #f))
     (when (and size (or length width height))
       (raise-syntax-error 'cuboid "use either size or named dimensions" stx))
     (unless (or size (and length width height))
       (raise-syntax-error
        'cuboid "size or length, width, and height are required" stx))
     (define dimensions (or size #`(list #,length #,width #,height)))
     #`(if (csg-context-active?)
           #,(if (scene-only-settings? values)
                 #'(error 'cuboid
                          "name, material, precedence, and metal-thickness belong on the enclosing with-body")
                 #`(csg-cuboid #,dimensions
                               #,@(anchor-keywords values #''center)))
           (add-cuboid/size #,(requested-name-expression values) #,dimensions
                            #,@(material-keywords values)
                            #,@(optional-keyword values 'precedence #'#:precedence)
                            #,@(optional-keyword values 'metal-thickness #'#:metal-thickness)
                            #,@(anchor-keywords values #''center)))]))

(define-syntax (sphere stx)
  (syntax-parse stx
    [(_ old-name:id setting ...)
     #:when (not (memq (syntax-e #'old-name)
                       '(name radius diameter material precedence anchor
                              segments metal-thickness)))
     (raise-syntax-error
      'sphere "positional names are not supported; use name VALUE" stx #'old-name)]
    [(_ setting ...)
     (define values
       (settings 'sphere stx #'(setting ...)
                 '(name radius diameter material precedence anchor segments
                          metal-thickness)
                 "expected sphere setting/value pairs"))
     (define radius (hash-ref values 'radius #f))
     (define diameter (hash-ref values 'diameter #f))
     (unless (or (and radius (not diameter)) (and diameter (not radius)))
       (raise-syntax-error 'sphere "specify exactly one of radius or diameter" stx))
     #`(if (csg-context-active?)
           #,(if (scene-only-settings? values)
                 #'(error 'sphere
                          "name, material, precedence, and metal-thickness belong on the enclosing with-body")
                 #`(csg-sphere
                    #,(or radius #`(/ #,diameter 2))
                    #,@(anchor-keywords values #''center)
                    #,@(optional-keyword values 'segments #'#:segments)))
           (add-solid-sphere
            #,(requested-name-expression values)
            #,(or radius #`(/ #,diameter 2))
            #,@(material-keywords values)
            #,@(optional-keyword values 'precedence #'#:precedence)
            #,@(optional-keyword values 'metal-thickness #'#:metal-thickness)
            #,@(anchor-keywords values #''center)
            #,@(optional-keyword values 'segments #'#:segments)))]))

(define-syntax (cylinder stx)
  (syntax-parse stx
    [(_ radius:expr) #'(turtle-cylinder-warp radius)]
    [(_ old-name:id setting ...)
     #:when (not (memq (syntax-e #'old-name)
                       '(name length diameter radius material precedence anchor
                              segments metal-thickness)))
     (raise-syntax-error
      'cylinder "positional names are not supported; use name VALUE" stx #'old-name)]
    [(_ setting ...)
     (define values
       (settings 'cylinder stx #'(setting ...)
                 '(name length diameter radius material precedence anchor segments
                          metal-thickness)
                 "expected cylinder setting/value pairs"))
     (define length (hash-ref values 'length #f))
     (define diameter (hash-ref values 'diameter #f))
     (define radius (hash-ref values 'radius #f))
     (unless length (raise-syntax-error 'cylinder "length is required" stx))
     (unless (or (and diameter (not radius)) (and radius (not diameter)))
       (raise-syntax-error 'cylinder "specify exactly one of diameter or radius" stx))
     #`(if (csg-context-active?)
           #,(if (scene-only-settings? values)
                 #'(error 'cylinder
                          "name, material, precedence, and metal-thickness belong on the enclosing with-body")
                 #`(csg-cylinder
                    #,length #,(or diameter #`(* 2 #,radius))
                    #,@(anchor-keywords values #''center)
                    #,@(optional-keyword values 'segments #'#:segments)))
           (add-solid-cylinder
            #,(requested-name-expression values)
            #,length #,(or diameter #`(* 2 #,radius))
            #,@(material-keywords values)
            #,@(optional-keyword values 'precedence #'#:precedence)
            #,@(optional-keyword values 'metal-thickness #'#:metal-thickness)
            #,@(anchor-keywords values #''center)
            #,@(optional-keyword values 'segments #'#:segments)))]))

(define-syntax (capsule stx)
  (syntax-parse stx
    [(_ old-name:id setting ...)
     #:when (not (memq (syntax-e #'old-name)
                       '(name length diameter radius material precedence anchor
                              segments metal-thickness)))
     (raise-syntax-error
      'capsule "positional names are not supported; use name VALUE" stx #'old-name)]
    [(_ setting ...)
     (define values
       (settings 'capsule stx #'(setting ...)
                 '(name length diameter radius material precedence anchor segments
                          metal-thickness)
                 "expected capsule setting/value pairs"))
     (define length (hash-ref values 'length #f))
     (define diameter (hash-ref values 'diameter #f))
     (define radius (hash-ref values 'radius #f))
     (unless length (raise-syntax-error 'capsule "length is required" stx))
     (unless (or (and diameter (not radius)) (and radius (not diameter)))
       (raise-syntax-error 'capsule "specify exactly one of diameter or radius" stx))
     #`(if (csg-context-active?)
           #,(if (scene-only-settings? values)
                 #'(error 'capsule
                          "name, material, precedence, and metal-thickness belong on the enclosing with-body")
                 #`(csg-capsule
                    #,length #,(or diameter #`(* 2 #,radius))
                    #,@(anchor-keywords values #''center)
                    #,@(optional-keyword values 'segments #'#:segments)))
           (add-solid-capsule
            #,(requested-name-expression values)
            #,length #,(or diameter #`(* 2 #,radius))
            #,@(material-keywords values)
            #,@(optional-keyword values 'precedence #'#:precedence)
            #,@(optional-keyword values 'metal-thickness #'#:metal-thickness)
            #,@(anchor-keywords values #''center)
            #,@(optional-keyword values 'segments #'#:segments)))]))

(define-syntax (stl stx)
  (syntax-parse stx
    [(_ old-name:id setting ...)
     #:when (not (memq (syntax-e #'old-name)
                       '(name path material precedence anchor)))
     (raise-syntax-error
      'stl "positional names are not supported; use name VALUE" stx #'old-name)]
    [(_ setting ...)
     (define values
       (settings 'stl stx #'(setting ...)
                 '(name path material precedence anchor)
                 "expected name, path, material, precedence, or anchor setting/value pairs"))
     (define path (hash-ref values 'path #f))
     (unless path (raise-syntax-error 'stl "path is required" stx))
     #`(if (csg-context-active?)
           #,(if (scene-only-settings? values)
                 #'(error 'stl
                          "name, material, and precedence belong on the enclosing with-body")
                 #`(csg-stl #,path
                            #,@(anchor-keywords values #''center)))
           (add-stl-body #,(requested-name-expression values) #,path
                         #,@(material-keywords values)
                         #,@(optional-keyword values 'precedence #'#:precedence)
                         #,@(anchor-keywords values #''center)))]))
