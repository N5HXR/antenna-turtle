#lang racket

(require rackunit
         (prefix-in m: manifold)
         "../antenna-turtle/main.rkt")

(define (m-point->list point)
  (list (m:point3-x point) (m:point3-y point) (m:point3-z point)))

(define (point->list point)
  (list (point3-x point) (point3-y point) (point3-z point)))

(define (body-bounds body)
  (define-values (minimum maximum) (m:solid-bounds (solid-body-solid body)))
  (values (m-point->list minimum) (m-point->list maximum)))

(define (check-point~= actual expected [epsilon 1e-12])
  (for ([actual-coordinate (in-list actual)]
        [expected-coordinate (in-list expected)])
    (check-= actual-coordinate expected-coordinate epsilon)))

(test-case "with-traces sweeps orthogonal and arbitrary planar paths"
  (reset-model!)
  (define orthogonal
    (with-material copper
      (with-traces 3
        thickness 0.035
        (move forward 10)
        (turn left 90)
        (move forward 10))))
  (check-true (regexp-match? #rx"^trace" (symbol->string (planar-sheet-name orthogonal))))
  (check-false (symbol-interned? (planar-sheet-name orthogonal)))
  (check-equal? (planar-sheet-mesh-edges orthogonal) 'metal)
  (check-= (planar-sheet-trace-width orthogonal) 3 1e-12)
  (check-equal? (length (planar-sheet-boundaries orthogonal)) 1)

  (move right 20)
  (define diagonal
    (with-traces 2
      name diagonal
      (move forward 5)
      (turn left 45)
      (move forward 5)))
  (check-equal? (planar-sheet-name diagonal) 'diagonal)
  (check-true (> (length (planar-sheet-points diagonal)) 4))
  (check-true (> (length (planar-sheet-polygons diagonal)) 1))
  (check-true
   (andmap (lambda (polygon) (= (length polygon) 3))
           (planar-sheet-polygons diagonal)))
  (clear-bodies))

(test-case "with-traces closes loops and rejects branching and off-plane motion"
  (reset-model!)
  (define loop-trace
    (with-traces 1
      (move forward 4)
      (turn left 90)
      (move forward 4)
      (turn left 90)
      (move forward 4)
      (turn left 90)
      (move forward 4)))
  (check-equal? (length (planar-sheet-boundaries loop-trace)) 2)
  (check-true (> (length (planar-sheet-polygons loop-trace)) 4))
  (clear-bodies)
  (check-exn #rx"branch or discontinue"
             (lambda ()
               (with-traces 1
                 (from-here (move forward 1)))))
  (check-exn #rx"left the trace plane"
             (lambda ()
               (with-traces 1 (move up 1))))
  (clear-bodies))

(test-case "with-traces accepts every axial plane and rejects an oblique plane"
  (reset-model!)
  (turn up 90)
  (define vertical
    (with-traces 1
      (move forward 4)
      (turn left 90)
      (move forward 2)))
  (check-= (abs (point3-x (planar-sheet-normal vertical))) 1 1e-12)
  (clear-bodies)
  (reset-model!)
  (turn up 17)
  (check-exn #rx"align with the global XY, XZ, or YZ plane"
             (lambda ()
               (with-traces 1 (move forward 2))))
  (clear-bodies))

(test-case "solid model names are optional and allocated uniquely"
  (reset-model!)
  (define first-sheet (sheet rect size '(2 1)))
  (define second-sheet (sheet rect size '(2 1)))
  (define first-body (cuboid size '(1 1 1)))
  (define second-body
    (cuboid size '(1 1 1) material aluminum metal-thickness 0.1))
  (define explicitly-generated
    (cuboid name (gensym 'custom-body) size '(1 1 1)))
  (define element
    (lumped-element up resistance 50 gap 1 size '(1 1)))
  (check-not-equal? (planar-sheet-name first-sheet)
                    (planar-sheet-name second-sheet))
  (check-false (symbol-interned? (planar-sheet-name first-sheet)))
  (check-not-equal? (solid-body-name first-body)
                    (solid-body-name second-body))
  (check-false (symbol-interned? (solid-body-name first-body)))
  (check-equal? (solid-body-material second-body) aluminum)
  (check-= (solid-body-metal-thickness second-body) 0.1 1e-12)
  (check-false (symbol-interned? (solid-body-name explicitly-generated)))
  (check-true
   (regexp-match? #rx"^custom-body"
                  (symbol->string (solid-body-name explicitly-generated))))
  (check-false (symbol-interned? (lumped-component-name element)))
  (clear-bodies))

(test-case "legacy positional solid names report the named-pair migration"
  (check-exn #rx"positional names are not supported; use name VALUE"
             (lambda ()
               (expand #'(cuboid legacy size '(1 1 1)))))
  (check-exn #rx"positional names are not supported; use name VALUE"
             (lambda ()
               (expand #'(with-body legacy (cuboid size '(1 1 1)))))))

(test-case "with-traces cannot be mixed with active wire construction"
  (reset-model!)
  (check-exn #rx"wire construction is active"
             (lambda ()
               (with-wire
                 (with-traces 1 (move forward 2)))))
  (clear-wires)
  (clear-bodies))

(test-case "with-scale scales raw Manifold bodies around their selected anchor"
  (reset-model!)
  (define source (m:cube 2 4 6 #:center? #t))
  (define placed
    (with-scale 0.001
      (body name block geometry source anchor center precedence 12)))
  (define-values (minimum maximum) (body-bounds placed))
  (check-point~= minimum '(-0.001 -0.002 -0.003))
  (check-point~= maximum '(0.001 0.002 0.003))
  (check-equal? (solid-body-priority placed) 12)
  (m:solid-close! source)
  (clear-bodies))

(test-case "cuboid anchors use turtle-relative bounding-box faces"
  (reset-model!)
  (define centered (cuboid name centered size '(4 2 6)))
  (define-values (center-min center-max) (body-bounds centered))
  (check-point~= center-min '(-2 -1 -3))
  (check-point~= center-max '(2 1 3))
  (check-equal? (solid-body-priority centered) 20)
  (clear-bodies)

  (define cornered
    (cuboid name cornered
      length 4 width 2 height 6
      anchor '(bottom left)))
  (define-values (corner-min corner-max) (body-bounds cornered))
  (check-point~= corner-min '(-2 -2 0))
  (check-point~= corner-max '(2 0 6))
  (clear-bodies))

(test-case "with-body builds one anchored Boolean difference"
  (reset-model!)
  (define shield
    (with-scale millimeters
      (with-body name shield
        material aluminum
        precedence 100
        metal-thickness 2
        anchor bottom
        (difference
          (cuboid size '(20 10 12) anchor bottom)
          (from-here
            (move up 2)
            (cuboid size '(16 6 10) anchor bottom))))))
  (check-equal? (length (model-bodies)) 1)
  (check-eq? shield (first (model-bodies)))
  (check-equal? (solid-body-material shield) aluminum)
  (check-equal? (solid-body-priority shield) 100)
  (check-= (solid-body-metal-thickness shield) 0.002 1e-15)
  (define-values (minimum maximum) (body-bounds shield))
  (check-point~= minimum '(-0.01 -0.005 0) 1e-10)
  (check-point~= maximum '(0.01 0.005 0.012) 1e-10)
  (check-= (m:solid-volume (solid-body-solid shield)) 1.44e-6 1e-12)
  (clear-bodies))

(test-case "with-body supports union, intersection, hull, and turtle placement"
  (reset-model!)
  (define start (here))
  (define joined
    (with-body name joined
      anchor origin
      ;; Top-level primitives are implicitly unioned.
      (cuboid size '(2 2 2))
      (from-here
        (move forward 2)
        (cuboid size '(2 2 2)))))
  (check-equal? (here) start)
  (define-values (joined-min joined-max) (body-bounds joined))
  (check-point~= joined-min '(-1 -1 -1))
  (check-point~= joined-max '(3 1 1))
  (check-= (m:solid-volume (solid-body-solid joined)) 16 1e-10)

  (move left 10)
  (define overlap
    (with-body name overlap
      anchor origin
      (intersect
        (cuboid size '(2 2 2))
        (from-here
          (move forward 1)
          (cuboid size '(2 2 2))))))
  (check-= (m:solid-volume (solid-body-solid overlap)) 4 1e-10)

  (move left 10)
  (define bridged
    (with-body name bridged
      anchor origin
      (hull
        (sphere diameter 2 segments 16)
        (from-here
          (move forward 4)
          (sphere diameter 2 segments 16)))))
  (define-values (bridged-min bridged-max) (body-bounds bridged))
  (check-= (first bridged-min) -1 1e-10)
  (check-= (first bridged-max) 5 1e-10)
  (clear-bodies))

(test-case "scale uniformly transforms a CSG expression around the turtle"
  (reset-model!)
  (define scaled
    (with-body name scaled
      anchor origin
      (scale 2
        (cuboid size '(2 4 6)))))
  (define-values (minimum maximum) (body-bounds scaled))
  (check-point~= minimum '(-2 -4 -6))
  (check-point~= maximum '(2 4 6))
  ;; The existing one-argument stateful scale remains available in a body.
  (move left 20)
  (define state-scaled
    (with-body name state-scaled
      anchor origin
      (scale 2)
      (cuboid size '(2 2 2))))
  (define-values (state-min state-max) (body-bounds state-scaled))
  (check-point~= state-min '(-2 18 -2))
  (check-point~= state-max '(2 22 2))
  (clear-bodies))

(test-case "material context and concise dielectric construction set precedence"
  (reset-model!)
  (define substrate (dielectric name foam er 1.15))
  (define placed
    (with-material substrate
      (cuboid name substrate size '(2 3 0.5) anchor bottom)))
  (check-equal? (solid-body-material placed) substrate)
  (check-equal? (solid-body-priority placed) 10)
  (define-values (minimum maximum) (body-bounds placed))
  (check-point~= minimum '(-1 -1.5 0))
  (check-point~= maximum '(1 1.5 0.5))
  (clear-bodies))

(test-case "lossy dielectrics and finite conductors preserve physical intent"
  (reset-model!)
  (define fr4
    (dielectric name fr4 er 4.4 loss-tangent 0.02 loss-frequency 435))
  (check-equal? (material-loss-value (em-material-loss-spec fr4)) 0.02)
  (check-equal? (material-loss-reference-frequency
                 (em-material-loss-spec fr4))
                435)
  (define custom-metal
    (conductor name plated-metal conductivity 2.4e7))
  (define placed
    (with-scale 0.001
      (cuboid name shield size '(20 10 2) material custom-metal
              metal-thickness 0.5)))
  (check-equal? (em-material-kind (solid-body-material placed)) 'conductor)
  (check-= (solid-body-metal-thickness placed) 0.0005 1e-15)
  (define trace
    (with-scale 0.001
      (sheet rect name trace size '(10 1) material copper thickness 0.035)))
  (check-= (planar-sheet-thickness trace) 0.000035 1e-15)
  (clear-bodies))

(test-case "solid cylinders and spheres follow the turtle up axis"
  (reset-model!)
  (define cylinder-body
    (cylinder name mast length 4 diameter 2 anchor bottom segments 16))
  (define-values (cylinder-min cylinder-max) (body-bounds cylinder-body))
  (check-point~= cylinder-min '(-1 -1 0) 1e-10)
  (check-point~= cylinder-max '(1 1 4) 1e-10)
  (clear-bodies)

  (move forward 5)
  (define sphere-body (sphere name marker diameter 2))
  (define-values (sphere-min sphere-max) (body-bounds sphere-body))
  (check-point~= sphere-min '(4 -1 -1) 1e-10)
  (check-point~= sphere-max '(6 1 1) 1e-10)
  (clear-bodies))

(test-case "capsule start and end anchors are cylindrical endpoint centers"
  (reset-model!)
  (define first-capsule
    (capsule name first length 4 diameter 2 anchor start segments 16))
  (define-values (first-min first-max) (body-bounds first-capsule))
  (check-= (third first-min) -1 1e-10)
  (check-= (third first-max) 5 1e-10)

  (move up 4)
  (define second-capsule
    (capsule name second length 3 radius 1 anchor start segments 16))
  (define-values (second-min second-max) (body-bounds second-capsule))
  (check-= (third second-min) 3 1e-10)
  (check-= (third second-max) 8 1e-10)
  (clear-bodies))

(test-case "rect sheets and explicit ports scale while automatic ports do not"
  (reset-model!)
  ;; A sheet material's physical thickness is part of the scaled geometry.
  (define copper
    (conducting-sheet-material
     #:name 'copper #:conductivity 5.8e7 #:thickness 0.035))
  (define-values (placed-sheet explicit-port automatic-port)
    (with-scale 0.001
      (values
       (sheet rect name ground size '(20 10) material copper mesh-edges metal)
       (port up name explicit size '(4 6) gap 2 precedence 15)
       (port forward name automatic))))
  (define points (map point->list (planar-sheet-points placed-sheet)))
  (check-point~= (first points) '(-0.01 -0.005 0))
  (check-point~= (third points) '(0.01 0.005 0))
  (check-= (em-material-thickness (planar-sheet-material placed-sheet))
           0.000035 1e-15)
  (check-= (lumped-port-gap explicit-port) 0.002 1e-15)
  (check-= (lumped-port-width explicit-port) 0.004 1e-15)
  (check-= (lumped-port-depth explicit-port) 0.006 1e-15)
  (check-equal? (lumped-port-priority explicit-port) 15)
  (check-equal? (lumped-port-gap automatic-port) (/ (model-wavelength) 1000))
  (check-equal? (lumped-port-width automatic-port) (/ (model-wavelength) 1000))
  (check-equal? (lumped-port-depth automatic-port) (/ (model-wavelength) 1000))
  (clear-bodies))
