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

(test-case "with-scale scales raw Manifold bodies around their selected anchor"
  (reset-model!)
  (define source (m:cube 2 4 6 #:center? #t))
  (define placed
    (with-scale 0.001
      (body block geometry source anchor center precedence 12)))
  (define-values (minimum maximum) (body-bounds placed))
  (check-point~= minimum '(-0.001 -0.002 -0.003))
  (check-point~= maximum '(0.001 0.002 0.003))
  (check-equal? (solid-body-priority placed) 12)
  (m:solid-close! source)
  (clear-bodies))

(test-case "cuboid anchors use turtle-relative bounding-box faces"
  (reset-model!)
  (define centered (cuboid centered size '(4 2 6)))
  (define-values (center-min center-max) (body-bounds centered))
  (check-point~= center-min '(-2 -1 -3))
  (check-point~= center-max '(2 1 3))
  (check-equal? (solid-body-priority centered) 20)
  (clear-bodies)

  (define cornered
    (cuboid cornered
      length 4 width 2 height 6
      anchor '(bottom left)))
  (define-values (corner-min corner-max) (body-bounds cornered))
  (check-point~= corner-min '(-2 -2 0))
  (check-point~= corner-max '(2 0 6))
  (clear-bodies))

(test-case "material context and concise dielectric construction set precedence"
  (reset-model!)
  (define substrate (dielectric name foam er 1.15))
  (define placed
    (with-material substrate
      (cuboid substrate size '(2 3 0.5) anchor bottom)))
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
      (cuboid shield size '(20 10 2) material custom-metal
              metal-thickness 0.5)))
  (check-equal? (em-material-kind (solid-body-material placed)) 'conductor)
  (check-= (solid-body-metal-thickness placed) 0.0005 1e-15)
  (define trace
    (with-scale 0.001
      (sheet rect trace size '(10 1) material copper thickness 0.035)))
  (check-= (planar-sheet-thickness trace) 0.000035 1e-15)
  (clear-bodies))

(test-case "solid cylinders and spheres follow the turtle up axis"
  (reset-model!)
  (define cylinder-body
    (cylinder mast length 4 diameter 2 anchor bottom segments 16))
  (define-values (cylinder-min cylinder-max) (body-bounds cylinder-body))
  (check-point~= cylinder-min '(-1 -1 0) 1e-10)
  (check-point~= cylinder-max '(1 1 4) 1e-10)
  (clear-bodies)

  (move forward 5)
  (define sphere-body (sphere marker diameter 2))
  (define-values (sphere-min sphere-max) (body-bounds sphere-body))
  (check-point~= sphere-min '(4 -1 -1) 1e-10)
  (check-point~= sphere-max '(6 1 1) 1e-10)
  (clear-bodies))

(test-case "capsule start and end anchors are cylindrical endpoint centers"
  (reset-model!)
  (define first-capsule
    (capsule first length 4 diameter 2 anchor start segments 16))
  (define-values (first-min first-max) (body-bounds first-capsule))
  (check-= (third first-min) -1 1e-10)
  (check-= (third first-max) 5 1e-10)

  (move up 4)
  (define second-capsule
    (capsule second length 3 radius 1 anchor start segments 16))
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
       (sheet rect ground size '(20 10) material copper mesh-edges metal)
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
