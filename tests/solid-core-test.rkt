#lang racket

(require rackunit
         (prefix-in m: manifold)
         "../antenna-turtle/main.rkt"
         "../antenna-turtle/private/solid-view.rkt"
         "../antenna-turtle/private/wire-solid.rkt")

(define (m-point->list point)
  (list (m:point3-x point) (m:point3-y point) (m:point3-z point)))

(define (body-bounds body)
  (define-values (minimum maximum) (m:solid-bounds (solid-body-solid body)))
  (values (m-point->list minimum) (m-point->list maximum)))

(test-case "body DSL places an owned Manifold copy in the turtle frame"
  (reset-model!)
  (move forward 2)
  (turn left 90)
  (define source (m:cube 1))
  (define placed
    (body radiator
      geometry source))
  (define-values (minimum maximum) (body-bounds placed))
  (check-= (first minimum) 1 1e-12)
  (check-= (second minimum) 0 1e-12)
  (check-= (third minimum) 0 1e-12)
  (check-= (first maximum) 2 1e-12)
  (check-= (second maximum) 1 1e-12)
  (check-= (third maximum) 1 1e-12)
  (check-equal? (solid-body-material placed) pec)
  (check-equal? (solid-body-coordinates placed) 'local)

  ;; Clearing the scene closes only its transformed copy.
  (clear-bodies)
  (check-true (m:solid-closed? (solid-body-solid placed)))
  (check-false (m:solid-closed? source))
  (m:solid-close! source))

(test-case "world-coordinate bodies bypass turtle placement"
  (reset-model!)
  (move up 20)
  (define source (m:cube 2))
  (define placed
    (body enclosure
      geometry source
      coordinates world
      priority 7))
  (define-values (minimum maximum) (body-bounds placed))
  (check-equal? minimum '(0.0 0.0 0.0))
  (check-equal? maximum '(2.0 2.0 2.0))
  (check-equal? (solid-body-priority placed) 7)
  (m:solid-close! source)
  (clear-bodies))

(test-case "center anchor places a primitive's bounds center at the turtle"
  (reset-model!)
  (move forward 5)
  (define source (m:cylinder 4 1 #:segments 16))
  (define placed
    (body element
      geometry source
      anchor center))
  (define-values (minimum maximum) (body-bounds placed))
  (check-equal? (map (lambda (low high) (/ (+ low high) 2)) minimum maximum)
                '(5.0 0.0 0.0))
  (m:solid-close! source)
  (clear-bodies))

(test-case "lossless dielectrics and overlap priorities validate explicitly"
  (reset-model!)
  (define substrate
    (dielectric #:name 'substrate #:relative-permittivity 4.4))
  (check-equal? (em-material-relative-permittivity substrate) 4.4)
  (check-equal? (em-material-relative-permeability substrate) 1)

  (define first-shape (m:cube 2))
  (define second-shape (m:cube 2))
  (add-body 'dielectric substrate first-shape #:coordinates 'world)
  (add-body 'metal pec second-shape #:coordinates 'world)
  (check-exn #rx"distinct explicit priorities" validate-solid-scene!)
  (m:solid-close! first-shape)
  (m:solid-close! second-shape)
  (clear-bodies)

  (define prioritized-first (m:cube 2))
  (define prioritized-second (m:cube 2))
  (add-body 'dielectric substrate prioritized-first
            #:priority 10 #:coordinates 'world)
  (add-body 'metal pec prioritized-second
            #:priority 20 #:coordinates 'world)
  (check-not-exn validate-solid-scene!)
  (m:solid-close! prioritized-first)
  (m:solid-close! prioritized-second)
  (clear-bodies))

(test-case "a sheet touching a different volume material needs priorities"
  (reset-model!)
  (define substrate-material
    (dielectric #:name 'substrate #:relative-permittivity 2.2))
  (define first-substrate (m:cube 2 2 1))
  (add-body 'substrate substrate-material first-substrate #:coordinates 'world)
  (add-sheet 'ground pec '((0 0) (2 0) (2 2) (0 2))
             #:coordinates 'world)
  (check-exn #rx"distinct explicit priorities" validate-solid-scene!)
  (m:solid-close! first-substrate)
  (clear-bodies)

  (define second-substrate (m:cube 2 2 1))
  (add-body 'substrate substrate-material second-substrate
            #:priority 10 #:coordinates 'world)
  (add-sheet 'ground pec '((0 0) (2 0) (2 2) (0 2))
             #:priority 20 #:coordinates 'world)
  (check-not-exn validate-solid-scene!)
  (m:solid-close! second-substrate)
  (clear-bodies))

(test-case "planar sheets and ports use the current turtle pose"
  (reset-model!)
  (model frequency 100 impedance 75)
  (move forward 3)
  (turn left 90)
  (define outline '((-1 -2) (1 -2) (1 2) (-1 2)))
  (define placed-sheet
    (sheet reflector
      points outline
      material pec
      mesh-edges metal))
  (check-equal? (length (planar-sheet-points placed-sheet)) 4)
  (check-equal? (planar-sheet-normal placed-sheet) (point3 0 0 1))
  (check-equal? (planar-sheet-mesh-edges placed-sheet) 'metal)

  (define placed-port (port forward priority 17))
  (check-equal? (lumped-port-name placed-port) "port-1")
  (check-equal? (lumped-port-impedance placed-port) 75)
  (check-equal? (lumped-port-center placed-port) (point3 3 0 0))
  (check-equal? (lumped-port-direction placed-port) (point3 0 1 0))
  (check-equal? (lumped-port-gap placed-port) (/ (model-wavelength) 1000))
  (check-equal? (lumped-port-width placed-port) (/ (model-wavelength) 1000))
  (check-equal? (lumped-port-depth placed-port) (/ (model-wavelength) 1000))
  (check-equal? (lumped-port-priority placed-port) 17)
  (check-exn exn:fail:contract?
             (lambda () (port forward priority 1.5))))

(test-case "clear-bodies clears subordinate sheets and ports but not wires"
  (reset-model!)
  (with-wire (move forward 1))
  (define source (m:cube 1))
  (body radome geometry source)
  (sheet ground points '((0 0) (1 0) (0 1)))
  (port up name "feed")
  (move forward 0.5)
  (lumped-element up name load resistance (* 50 ohms)
                  gap 0.1 size '(0.1 0.1))
  (mesh-point)
  (mesh-plane xy)
  (check-equal? (length (model-edges)) 1)
  (check-equal? (length (model-bodies)) 1)
  (check-equal? (length (model-sheets)) 1)
  (check-equal? (length (model-ports)) 1)
  (check-equal? (length (model-components)) 1)
  (check-true (lumped-component-caps (first (model-components))))
  (check-equal? (length (model-mesh-constraints)) 2)

  (clear-bodies)
  (check-equal? (length (model-edges)) 1)
  (check-equal? (model-bodies) '())
  (check-equal? (model-sheets) '())
  (check-equal? (model-ports) '())
  (check-equal? (model-components) '())
  (check-equal? (model-mesh-constraints) '())
  (m:solid-close! source))

(test-case "lumped elements scale geometry but retain SI electrical values"
  (reset-model!)
  (define element
    (with-scale millimeters
      (move forward 10)
      (lumped-element up
        name matching-network
        resistance (* 50 ohms)
        inductance (* 2.2 nanohenries)
        capacitance (* 3.3 picofarads)
        topology series
        caps #f
        gap 2
        size '(3 4))))
  (check-equal? (lumped-component-name element) 'matching-network)
  (check-= (point3-x (lumped-component-center element)) 0.01 1e-15)
  (check-= (point3-y (lumped-component-center element)) 0 1e-15)
  (check-= (point3-z (lumped-component-center element)) 0 1e-15)
  (check-= (lumped-component-gap element) 0.002 1e-15)
  (check-= (lumped-component-width element) 0.003 1e-15)
  (check-= (lumped-component-depth element) 0.004 1e-15)
  (check-equal? (lumped-component-resistance element) 50)
  (check-= (lumped-component-inductance element) 2.2e-9 1e-20)
  (check-= (lumped-component-capacitance element) 3.3e-12 1e-22)
  (check-equal? (lumped-component-topology element) 'series)
  (check-false (lumped-component-caps element))
  (check-exn
   #rx"topology is required"
   (lambda ()
     (add-lumped-element 'up #:name 'invalid
                         #:resistance 50 #:capacitance 1e-12
                         #:gap 1 #:width 1 #:depth 1)))
  (clear-bodies))

(test-case "mesh constraints capture the current global turtle coordinate"
  (reset-model!)
  (with-scale 0.001
    (move forward 20 left 30 up 40)
    (mesh-point)
    (mesh-plane xz))
  (define constraints (model-mesh-constraints))
  (define point-hint (first constraints))
  (define plane-hint (second constraints))
  (check-equal? (mesh-constraint-kind point-hint) 'point)
  (check-equal? (mesh-constraint-point point-hint)
                (point3 0.02 0.03 0.04))
  (check-false (mesh-constraint-plane point-hint))
  (check-equal? (mesh-constraint-kind plane-hint) 'plane)
  (check-equal? (mesh-constraint-plane plane-hint) 'xz)
  (check-equal? (mesh-constraint-normal plane-hint) (point3 0 1 0))
  (check-equal? (mesh-constraint-point plane-hint)
                (point3 0.02 0.03 0.04))
  (clear-bodies))

(test-case "reset-model clears both wire and physical geometry"
  (reset-model!)
  (define source (m:cube 1))
  (body block geometry source)
  (port right)
  (mesh-plane yz)
  (with-wire (move up 1))
  (reset-model!)
  (check-equal? (model-edges) '())
  (check-equal? (model-bodies) '())
  (check-equal? (model-ports) '())
  (check-equal? (model-mesh-constraints) '())
  (m:solid-close! source))

(test-case "solid placement rejects nonlinear and repeated construction scopes"
  (reset-model!)
  (define source (m:cube 1))
  (check-exn
   #rx"cannot place solid geometry inside with-warp"
   (lambda ()
     (with-warp (lambda (x y z) (list x y z))
       (body warped geometry source))))
  (check-exn
   #rx"cannot place solid geometry inside radial-repeat"
   (lambda ()
     (radial-repeat 2
       (body repeated geometry source))))
  (m:solid-close! source))

(test-case "solid model preview renders bodies and finite ports without a GUI"
  (reset-model!)
  (define source (m:cube 1 #:center? #t))
  (body radiator geometry source)
  (port up gap 0.1 width 0.2 depth 0.3)
  (define renderers (solid-model->plot-renderers))
  (check-true (> (length renderers) 2))
  (define bounds (call-with-values solid-model-cubic-bounds list))
  (check-equal? (length bounds) 6)
  (check-true (andmap real? bounds))
  (m:solid-close! source)
  (clear-bodies))

(test-case "solid model preview renders a sheet-only scene"
  (reset-model!)
  (sheet patch points '((-1 -1) (1 -1) (1 1) (-1 1)))
  (define renderers (solid-model->plot-renderers))
  (check-equal? (length renderers) 1)
  (clear-bodies))

(test-case "wire centerlines derive a temporary capsule union and feed gap"
  (reset-model!)
  ;; This frequency makes wavelength exactly one metre.
  (model frequency 299.792458 impedance 75)
  (with-wire
    (move up 1 feed (center "wire-feed" 1 0)))
  (define derived-body #f)
  (call-with-derived-wire-scene
   (lambda (derivation)
     (set! derived-body (wire-solid-derivation-body derivation))
     (check-equal? (length (model-bodies)) 1)
     (check-equal? (length (model-ports)) 1)
     (check-equal? (wire-solid-derivation-edge-count derivation) 1)
     (check-equal? (wire-solid-derivation-feed-edge-id derivation) 1)
     (check-= (wire-solid-derivation-feed-gap derivation) 0.001 1e-12)
     (define port (wire-solid-derivation-port derivation))
     (check-equal? (lumped-port-name port) "wire-feed")
     (check-equal? (lumped-port-impedance port) 75)
     (check-equal? (lumped-port-center port) (point3 0 0 1/2))
     (define solid (solid-body-solid derived-body))
     ;; The feed center has been removed while either arm remains conductive.
     (check-= (m:solid-winding-number solid '(0 0 0.5)) 0 1e-12)
     (check-true (> (m:solid-winding-number solid '(0 0 0.25)) 0.9))))
  ;; Derivation must neither mutate the live scene nor leak its native handle.
  (check-equal? (model-bodies) '())
  (check-equal? (model-ports) '())
  (check-true (m:solid-closed? (solid-body-solid derived-body))))
