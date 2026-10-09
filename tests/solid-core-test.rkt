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
      material pec))
  (check-equal? (length (planar-sheet-points placed-sheet)) 4)
  (check-equal? (planar-sheet-normal placed-sheet) (point3 0 0 1))

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
  (check-equal? (length (model-edges)) 1)
  (check-equal? (length (model-bodies)) 1)
  (check-equal? (length (model-sheets)) 1)
  (check-equal? (length (model-ports)) 1)

  (clear-bodies)
  (check-equal? (length (model-edges)) 1)
  (check-equal? (model-bodies) '())
  (check-equal? (model-sheets) '())
  (check-equal? (model-ports) '())
  (m:solid-close! source))

(test-case "reset-model clears both wire and physical geometry"
  (reset-model!)
  (define source (m:cube 1))
  (body block geometry source)
  (port right)
  (with-wire (move up 1))
  (reset-model!)
  (check-equal? (model-edges) '())
  (check-equal? (model-bodies) '())
  (check-equal? (model-ports) '())
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
