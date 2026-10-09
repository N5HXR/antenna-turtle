#lang racket/base

(require racket/list
         racket/math
         (prefix-in m: manifold)
         "core.rkt")

(provide
 (struct-out em-material)
 pec
 dielectric
 conducting-sheet-material

 (struct-out solid-body)
 (struct-out planar-sheet)
 (struct-out lumped-port)
 (struct-out solid-scene)
 current-solid-scene
 model-bodies
 model-sheets
 model-ports
 add-body
 add-sheet
 add-lumped-port
 lumped-port-start
 lumped-port-stop
 clear-bodies
 validate-solid-scene!)

;; Materials deliberately retain electric and magnetic fields that the first
;; OpenEMS implementation will not yet consume. This keeps loss, dispersion,
;; and isotropic magnetic materials from requiring a replacement data model.
(struct em-material
  (name kind relative-permittivity relative-permeability
        electric-conductivity magnetic-conductivity thickness)
  #:transparent)

(define pec
  (em-material 'pec 'pec #f #f #f #f 0))

(define (finite-real? value)
  (and (real? value) (rational? value)))

(define (positive-real who value description)
  (unless (and (finite-real? value) (positive? value))
    (raise-arguments-error who
                           (format "~a must be a positive finite real" description)
                           description value))
  value)

(define (nonnegative-real who value description)
  (unless (and (finite-real? value) (>= value 0))
    (raise-arguments-error
     who (format "~a must be a nonnegative finite real" description)
     description value))
  value)

(define (material-name who value)
  (unless (or (symbol? value)
              (and (string? value) (not (string=? value ""))))
    (raise-argument-error who "(or/c symbol? non-empty-string?)" value))
  value)

(define (dielectric #:name [name 'dielectric]
                    #:relative-permittivity epsilon-r
                    #:relative-permeability [mu-r 1])
  (material-name 'dielectric name)
  (positive-real 'dielectric epsilon-r "relative permittivity")
  (positive-real 'dielectric mu-r "relative permeability")
  (em-material name 'dielectric epsilon-r mu-r 0 0 #f))

(define (conducting-sheet-material
         #:name [name 'conducting-sheet]
         #:conductivity [conductivity 0]
         #:thickness [thickness 0])
  (material-name 'conducting-sheet-material name)
  (nonnegative-real
   'conducting-sheet-material conductivity "electric conductivity")
  (nonnegative-real 'conducting-sheet-material thickness "sheet thickness")
  (em-material name 'conducting-sheet #f #f conductivity 0 thickness))

;; A scene owns the transformed Manifold handles stored in its bodies. The
;; caller retains ownership of the source solid passed to add-body.
(struct solid-body
  (name material solid priority coordinates placement-transform)
  #:transparent)
(struct planar-sheet
  (name material points normal priority placement-transform)
  #:transparent)
(struct lumped-port
  (name impedance center direction transverse-u transverse-v
        gap width depth placement-transform)
  #:transparent)
(struct solid-scene (bodies sheets ports) #:mutable #:transparent)

(define current-solid-scene
  (make-parameter (solid-scene '() '() '())))

(define (model-bodies [scene (current-solid-scene)])
  (solid-scene-bodies scene))

(define (model-sheets [scene (current-solid-scene)])
  (solid-scene-sheets scene))

(define (model-ports [scene (current-solid-scene)])
  (solid-scene-ports scene))

(define identity-transform
  '((1 0 0 0)
    (0 1 0 0)
    (0 0 1 0)))

(define (scene-transform who coordinates)
  (case coordinates
    [(local) (current-turtle-affine-transform who)]
    [(world) identity-transform]
    [else
     (raise-argument-error who "(or/c 'local 'world)" coordinates)]))

(define (geometry-name who value)
  (unless (or (symbol? value)
              (and (string? value) (not (string=? value ""))))
    (raise-argument-error who "(or/c symbol? non-empty-string?)" value))
  value)

(define (validate-material who value)
  (unless (em-material? value)
    (raise-argument-error who "em-material?" value))
  value)

(define (validate-priority who value)
  (unless (or (not value) (exact-integer? value))
    (raise-argument-error who "(or/c #f exact-integer?)" value))
  value)

(define (used-name? name [scene (current-solid-scene)])
  (or (for/or ([body (in-list (solid-scene-bodies scene))])
        (equal? name (solid-body-name body)))
      (for/or ([sheet (in-list (solid-scene-sheets scene))])
        (equal? name (planar-sheet-name sheet)))))

(define (add-body name material geometry
                  #:priority [priority #f]
                  #:coordinates [coordinates 'local]
                  #:anchor [anchor 'origin])
  (geometry-name 'add-body name)
  (validate-material 'add-body material)
  (validate-priority 'add-body priority)
  (unless (memq anchor '(origin center))
    (raise-argument-error 'add-body "(or/c 'origin 'center)" anchor))
  (unless (m:solid? geometry)
    (raise-argument-error 'add-body "solid? from manifold" geometry))
  (when (m:solid-closed? geometry)
    (raise-arguments-error 'add-body "source solid has been closed"
                           "geometry" geometry))
  (when (used-name? name)
    (raise-arguments-error 'add-body "geometry names must be unique"
                           "name" name))
  (define placement (scene-transform 'add-body coordinates))
  (define effective-placement
    (if (eq? anchor 'origin)
        placement
        (let ()
          (define-values (minimum maximum) (m:solid-bounds geometry))
          (define center
            (list (/ (+ (m:point3-x minimum) (m:point3-x maximum)) 2)
                  (/ (+ (m:point3-y minimum) (m:point3-y maximum)) 2)
                  (/ (+ (m:point3-z minimum) (m:point3-z maximum)) 2)))
          (for/list ([row (in-list placement)])
            (append (take row 3)
                    (list (- (fourth row)
                             (for/sum ([coefficient (in-list (take row 3))]
                                       [coordinate (in-list center)])
                               (* coefficient coordinate)))))))))
  ;; transform always returns a distinct native handle, including identity.
  (define owned-solid (m:transform geometry effective-placement))
  (define body
    (solid-body name material owned-solid priority coordinates effective-placement))
  (define scene (current-solid-scene))
  (set-solid-scene-bodies!
   scene (append (solid-scene-bodies scene) (list body)))
  body)

(define (point-values who value count)
  (define values
    (cond
      [(and (list? value) (= (length value) count)) value]
      [(and (vector? value) (= (vector-length value) count))
       (vector->list value)]
      [else
       (raise-argument-error
        who (format "~a-element list or vector" count) value)]))
  (for ([item (in-list values)])
    (unless (finite-real? item)
      (raise-argument-error who "finite real coordinates" value)))
  values)

(define (transform-vector matrix value)
  (define coordinates (point-values 'transform-vector value 3))
  (apply point3
         (for/list ([row (in-list matrix)])
           (for/sum ([coefficient (in-list (take row 3))]
                     [coordinate (in-list coordinates)])
             (* coefficient coordinate)))))

(define (transform-point matrix value)
  (define direction (transform-vector matrix value))
  (point3 (+ (point3-x direction) (list-ref (first matrix) 3))
          (+ (point3-y direction) (list-ref (second matrix) 3))
          (+ (point3-z direction) (list-ref (third matrix) 3))))

(define (add-sheet name material points
                   #:priority [priority #f]
                   #:coordinates [coordinates 'local])
  (geometry-name 'add-sheet name)
  (validate-material 'add-sheet material)
  (unless (memq (em-material-kind material) '(pec conducting-sheet))
    (raise-arguments-error
     'add-sheet "sheet material must be PEC or a conducting-sheet material"
     "material" material))
  (validate-priority 'add-sheet priority)
  (unless (and (list? points) (>= (length points) 3))
    (raise-argument-error 'add-sheet "list of at least three 2D points" points))
  (when (used-name? name)
    (raise-arguments-error 'add-sheet "geometry names must be unique"
                           "name" name))
  (define placement (scene-transform 'add-sheet coordinates))
  (define world-points
    (for/list ([point (in-list points)])
      (define xy (point-values 'add-sheet point 2))
      (transform-point placement (list (first xy) (second xy) 0))))
  (define sheet
    (planar-sheet name material world-points
                  (transform-vector placement '(0 0 1))
                  priority placement))
  (define scene (current-solid-scene))
  (set-solid-scene-sheets!
   scene (append (solid-scene-sheets scene) (list sheet)))
  sheet)

(define direction-components
  (hash 'forward '(1 0 0)
        'forwards '(1 0 0)
        'back '(-1 0 0)
        'backward '(-1 0 0)
        'backwards '(-1 0 0)
        'left '(0 1 0)
        'right '(0 -1 0)
        'up '(0 0 1)
        'down '(0 0 -1)))

(define transverse-components
  ;; The ordering merely defines how width and depth are displayed. All three
  ;; vectors remain a right-handed local frame for the positive directions;
  ;; polarity reversal does not change the port box.
  (hash 'forward (list '(0 1 0) '(0 0 1))
        'forwards (list '(0 1 0) '(0 0 1))
        'back (list '(0 1 0) '(0 0 1))
        'backward (list '(0 1 0) '(0 0 1))
        'backwards (list '(0 1 0) '(0 0 1))
        'left (list '(1 0 0) '(0 0 1))
        'right (list '(1 0 0) '(0 0 1))
        'up (list '(1 0 0) '(0 1 0))
        'down (list '(1 0 0) '(0 1 0))))

(define (fresh-port-name [scene (current-solid-scene)])
  (define used (map lumped-port-name (solid-scene-ports scene)))
  (let loop ([index 1])
    (define candidate (format "port-~a" index))
    (if (member candidate used) (loop (add1 index)) candidate)))

(define (add-lumped-port direction
                         #:name [requested-name #f]
                         #:impedance [impedance (model-impedance)]
                         #:gap [gap (/ (model-wavelength) 1000)]
                         #:width [width (/ (model-wavelength) 1000)]
                         #:depth [depth (/ (model-wavelength) 1000)])
  (define local-direction (hash-ref direction-components direction #f))
  (unless local-direction
    (raise-argument-error
     'add-lumped-port
     "(or/c 'forward 'forwards 'back 'backward 'backwards 'left 'right 'up 'down)"
     direction))
  (when requested-name (geometry-name 'add-lumped-port requested-name))
  (positive-real 'add-lumped-port impedance "reference impedance")
  (positive-real 'add-lumped-port gap "gap")
  (nonnegative-real 'add-lumped-port width "width")
  (nonnegative-real 'add-lumped-port depth "depth")
  (define scene (current-solid-scene))
  (define name (or requested-name (fresh-port-name scene)))
  (when (for/or ([port (in-list (solid-scene-ports scene))])
          (equal? name (lumped-port-name port)))
    (raise-arguments-error 'add-lumped-port "port names must be unique"
                           "name" name))
  (define placement (current-turtle-affine-transform 'add-lumped-port))
  (define transverse (hash-ref transverse-components direction))
  (define port
    (lumped-port
     name impedance
     (transform-point placement '(0 0 0))
     (transform-vector placement local-direction)
     (transform-vector placement (first transverse))
     (transform-vector placement (second transverse))
     gap width depth placement))
  (set-solid-scene-ports!
   scene (append (solid-scene-ports scene) (list port)))
  port)

(define (point+scaled point vector scale)
  (point3 (+ (point3-x point) (* scale (point3-x vector)))
          (+ (point3-y point) (* scale (point3-y vector)))
          (+ (point3-z point) (* scale (point3-z vector)))))

(define (lumped-port-start port)
  (unless (lumped-port? port)
    (raise-argument-error 'lumped-port-start "lumped-port?" port))
  (point+scaled (lumped-port-center port)
                (lumped-port-direction port)
                (- (/ (lumped-port-gap port) 2))))

(define (lumped-port-stop port)
  (unless (lumped-port? port)
    (raise-argument-error 'lumped-port-stop "lumped-port?" port))
  (point+scaled (lumped-port-center port)
                (lumped-port-direction port)
                (/ (lumped-port-gap port) 2)))

(define (body-overlap? first-body second-body)
  (define overlap
    (m:intersection (solid-body-solid first-body)
                    (solid-body-solid second-body)))
  (dynamic-wind
    void
    (lambda ()
      (and (not (m:solid-empty? overlap))
           (positive? (m:solid-volume overlap))))
    (lambda () (m:solid-close! overlap))))

(define (point-axis point axis)
  (case axis
    [(0) (point3-x point)]
    [(1) (point3-y point)]
    [else (point3-z point)]))

(define (sheet-bounds sheet)
  (values
   (for/list ([axis (in-range 3)])
     (apply min (map (lambda (point) (point-axis point axis))
                     (planar-sheet-points sheet))))
   (for/list ([axis (in-range 3)])
     (apply max (map (lambda (point) (point-axis point axis))
                     (planar-sheet-points sheet))))))

(define (body-bounds body)
  (define-values (minimum maximum) (m:solid-bounds (solid-body-solid body)))
  (values (list (m:point3-x minimum) (m:point3-y minimum) (m:point3-z minimum))
          (list (m:point3-x maximum) (m:point3-y maximum) (m:point3-z maximum))))

(define (bounds-touch? first-minimum first-maximum second-minimum second-maximum)
  (for/and ([first-low (in-list first-minimum)]
            [first-high (in-list first-maximum)]
            [second-low (in-list second-minimum)]
            [second-high (in-list second-maximum)])
    (and (<= first-low second-high) (<= second-low first-high))))

(define (different-material-overlap! first-kind first-name first-material first-priority
                                     second-kind second-name second-material second-priority)
  (unless (or (equal? first-material second-material)
              (and first-priority second-priority
                   (not (= first-priority second-priority))))
    (raise-arguments-error
     'validate-solid-scene!
     "overlapping geometry with different materials needs distinct explicit priorities"
     (format "first ~a" first-kind) first-name
     "first priority" first-priority
     (format "second ~a" second-kind) second-name
     "second priority" second-priority)))

(define (validate-solid-scene! [scene (current-solid-scene)])
  (for* ([first-body (in-list (solid-scene-bodies scene))]
         [second-body (in-list (solid-scene-bodies scene))]
         #:when (< (index-of (solid-scene-bodies scene) first-body eq?)
                   (index-of (solid-scene-bodies scene) second-body eq?))
         #:unless (equal? (solid-body-material first-body)
                          (solid-body-material second-body)))
    (when (body-overlap? first-body second-body)
      (different-material-overlap!
       "body" (solid-body-name first-body) (solid-body-material first-body)
       (solid-body-priority first-body)
       "body" (solid-body-name second-body) (solid-body-material second-body)
       (solid-body-priority second-body))))
  ;; Manifold gives an exact volume/volume test above. Zero-thickness sheets
  ;; use conservative inclusive bounds: when unlike materials touch, the
  ;; programmer must state which CSXCAD primitive wins at that interface.
  (for* ([sheet (in-list (solid-scene-sheets scene))]
         [body (in-list (solid-scene-bodies scene))])
    (define-values (sheet-minimum sheet-maximum) (sheet-bounds sheet))
    (define-values (body-minimum body-maximum) (body-bounds body))
    (when (bounds-touch? sheet-minimum sheet-maximum body-minimum body-maximum)
      (different-material-overlap!
       "sheet" (planar-sheet-name sheet) (planar-sheet-material sheet)
       (planar-sheet-priority sheet)
       "body" (solid-body-name body) (solid-body-material body)
       (solid-body-priority body))))
  (for* ([first-sheet (in-list (solid-scene-sheets scene))]
         [second-sheet (in-list (solid-scene-sheets scene))]
         #:when (< (index-of (solid-scene-sheets scene) first-sheet eq?)
                   (index-of (solid-scene-sheets scene) second-sheet eq?)))
    (define-values (first-minimum first-maximum) (sheet-bounds first-sheet))
    (define-values (second-minimum second-maximum) (sheet-bounds second-sheet))
    (when (bounds-touch? first-minimum first-maximum second-minimum second-maximum)
      (different-material-overlap!
       "sheet" (planar-sheet-name first-sheet) (planar-sheet-material first-sheet)
       (planar-sheet-priority first-sheet)
       "sheet" (planar-sheet-name second-sheet) (planar-sheet-material second-sheet)
       (planar-sheet-priority second-sheet))))
  (void))

(define (clear-bodies)
  (for ([body (in-list (solid-scene-bodies (current-solid-scene)))])
    (define solid (solid-body-solid body))
    (unless (m:solid-closed? solid) (m:solid-close! solid)))
  ;; Ports and sheets are subordinate to the physical bodies they touch.
  (current-solid-scene (solid-scene '() '() '()))
  (void))

(register-model-reset-hook! clear-bodies)
