#lang racket

(require rackunit
         "../antenna-turtle/main.rkt")

(define (distance-from point center)
  (sqrt (+ (sqr (- (point3-x point) (point3-x center)))
           (sqr (- (point3-y point) (point3-y center)))
           (sqr (- (point3-z point) (point3-z center))))))

(define (coordinate-bounds vertices accessor)
  (define coordinates (map (lambda (vertex) (accessor (vertex-point vertex)))
                           vertices))
  (values (apply min coordinates) (apply max coordinates)))

(test-case "cuboid-wire-mesh anchors an equal-area conductive grid at a node"
  (reset-model!)
  (wire-diameter (* 2 millimeter))
  (with-conductivity 12345678
    (cuboid-wire-mesh
     size '(2 4 6)
     divisions '(2 4 6)
     anchor top))

  ;; Unit pitch on every axis makes the equal-area diameter exactly 1/pi.
  ;; There are 90 boundary vertices and 176 unique unit lattice edges.
  (check-equal? (length (model-vertices)) 90)
  (check-equal? (length (model-edges)) 176)
  (for ([edge (in-list (model-edges))])
    (check-= (wire-edge-diameter edge) (/ pi) 1e-12)
    (check-equal? (wire-edge-conductivity edge) 12345678))

  (define-values (xmin xmax)
    (coordinate-bounds (model-vertices) point3-x))
  (define-values (ymin ymax)
    (coordinate-bounds (model-vertices) point3-y))
  (define-values (zmin zmax)
    (coordinate-bounds (model-vertices) point3-z))
  (check-equal? (list xmin xmax ymin ymax zmin zmax) '(-1 1 -2 2 -6 0))
  (check-true
   (ormap (lambda (vertex) (equal? (vertex-point vertex) (here)))
          (model-vertices)))

  ;; The helper restores the caller's wire diameter and turtle state. A new
  ;; conductor starts on the existing top-center vertex rather than creating
  ;; a coincident, disconnected attachment point.
  (with-wire (move up 1))
  (define final-edge (last (model-edges)))
  (check-equal? (length (model-vertices)) 91)
  (check-equal? (vertex-point (wire-edge-start final-edge)) (point3 0 0 0))
  (check-equal? (wire-edge-diameter final-edge) (* 2 millimeter))
  (check-false (wire-edge-conductivity final-edge)))

(test-case "cuboid-wire-mesh requires its anchor to be a grid junction"
  (reset-model!)
  ;; Top centers X and Y, so both corresponding division counts must be even.
  (check-exn
   #rx"anchor must coincide with a wire-grid junction"
   (lambda ()
     (cuboid-wire-mesh size '(2 4 6) divisions '(3 4 6) anchor top)))
  (check-equal? (model-edges) '())

  ;; A corner lies on boundary planes and does not require even counts.
  (cuboid-wire-mesh
   size '(2 4 6)
   divisions '(1 3 5)
   anchor '(front left top))
  (check-true
   (ormap (lambda (vertex) (equal? (vertex-point vertex) (here)))
          (model-vertices))))

(test-case "cuboid-wire-mesh scales its derived diameter with its geometry"
  (reset-model!)
  (with-scale millimeter
    (cuboid-wire-mesh
     size '(2 4 6)
     divisions '(2 4 6)
     anchor top))

  ;; Local unit pitch becomes one millimetre, including the equal-area
  ;; diameter. Before this regression was fixed, only the coordinates scaled
  ;; and every grid wire remained roughly 0.318 metre in diameter.
  (for ([edge (in-list (model-edges))])
    (check-= (wire-edge-diameter edge) (/ (* 1000 pi)) 1e-15))
  (define-values (xmin xmax)
    (coordinate-bounds (model-vertices) point3-x))
  (define-values (_ymin _ymax)
    (coordinate-bounds (model-vertices) point3-y))
  (define-values (zmin zmax)
    (coordinate-bounds (model-vertices) point3-z))
  (check-equal? (list xmin xmax zmin zmax)
                (list -1/1000 1/1000 -6/1000 0)))

(test-case "cuboid-wire-mesh validates contextual settings"
  (check-exn exn:fail:syntax?
             (lambda () (expand #'(cuboid-wire-mesh divisions '(2 2 2)))))
  (check-exn exn:fail:syntax?
             (lambda () (expand #'(cuboid-wire-mesh size '(1 1 1)))))
  (check-exn exn:fail:syntax?
             (lambda ()
               (expand
                #'(cuboid-wire-mesh
                   size '(1 1 1) divisions '(2 2 2) spacing 1))))
  (reset-model!)
  (check-exn exn:fail:contract?
             (lambda ()
               (cuboid-wire-mesh size '(0 1 1) divisions '(2 2 2))))
  (check-exn exn:fail:contract?
             (lambda ()
               (cuboid-wire-mesh size '(1 1 1) divisions '(2 0 2))))
  (check-equal? (model-edges) '()))

(test-case "circular-wire-mesh draws shared ribs and rings without moving"
  (reset-model!)
  (move forward 3)
  (turn left 90)
  (define center (here))

  (circular-wire-mesh 4 8 2)

  ;; Eight two-segment ribs plus two eight-chord rings.
  (check-equal? (length (model-edges)) 32)
  (check-equal? (length (model-vertices)) 17)
  (check-equal? (here) center)
  (check-= (apply max
                  (map (lambda (vertex)
                         (distance-from (vertex-point vertex) center))
                       (model-vertices)))
           2
           1e-12)

  ;; Orientation, not merely position, has from-here semantics.
  (move forward 1)
  (check-= (point3-x (here)) 3 1e-12)
  (check-= (point3-y (here)) 1 1e-12)
  (check-= (point3-z (here)) 0 1e-12))

(test-case "circular-wire-mesh composes with curved surfaces"
  (reset-model!)
  (with-surface (paraboloid 2)
    (circular-wire-mesh 4 8 2))
  (check-equal? (length (model-edges)) 32)
  (check-equal? (length (model-vertices)) 17)
  (check-= (apply max
                  (map (lambda (vertex)
                         (point3-z (vertex-point vertex)))
                       (model-vertices)))
           1/2
           1e-12)
  (check-equal? (here) (point3 0 0 0)))

(test-case "circular-wire-mesh can leave an annular center opening"
  (reset-model!)
  (circular-wire-mesh 4 1 8 3)

  ;; Eight ribs span the two intervals between three rings. No vertex is
  ;; emitted at the center, so all 24 vertices lie on a ring.
  (check-equal? (length (model-edges)) 40)
  (check-equal? (length (model-vertices)) 24)
  (define radii
    (map (lambda (vertex)
           (distance-from (vertex-point vertex) (point3 0 0 0)))
         (model-vertices)))
  (for ([radius (in-list radii)])
    (check-true
     (ormap (lambda (expected) (< (abs (- radius expected)) 1e-12))
            '(1/2 5/4 2))))
  (check-false
   (ormap (lambda (vertex)
            (equal? (vertex-point vertex) (point3 0 0 0)))
          (model-vertices))))

(test-case "circular-wire-mesh preserves an enclosing wire trace"
  (reset-model!)
  (with-wire
    (move forward 1)
    (circular-wire-mesh 2 4 1)
    (move forward 1))
  ;; Four ribs and four ring chords are self-contained between the two outer
  ;; trace segments. The caller resumes from its pre-mesh source vertex.
  (check-equal? (length (model-edges)) 10)
  (check-equal? (vertex-point (wire-edge-start (last (model-edges))))
                (point3 1 0 0))
  (check-equal? (vertex-point (wire-edge-end (last (model-edges))))
                (point3 2 0 0)))

(test-case "circular-wire-mesh validates construction parameters"
  (reset-model!)
  (check-exn exn:fail:contract?
             (lambda () (circular-wire-mesh 0 8 2)))
  (check-exn exn:fail:contract?
             (lambda () (circular-wire-mesh 4 2 2)))
  (check-exn exn:fail:contract?
             (lambda () (circular-wire-mesh 4 8 0)))
  (check-exn exn:fail:contract?
             (lambda () (circular-wire-mesh 4 0 8 3)))
  (check-exn exn:fail:contract?
             (lambda () (circular-wire-mesh 4 4 8 3)))
  (check-exn exn:fail:contract?
             (lambda () (circular-wire-mesh 4 1 8 1)))
  (check-equal? (model-edges) '()))

(test-case "circular-shielded-reflector adds a segmented outer wall"
  (reset-model!)
  (move forward 3)
  (turn left 90)
  (define center (here))

  (circular-shielded-reflector 4 1 8 2 #:wall-ringcount 2)

  ;; The 32-edge floor gains two 8-edge vertical courses and two 8-chord
  ;; horizontal rings. The wall reuses the floor's outer eight vertices.
  (check-equal? (length (model-edges)) 64)
  (check-equal? (length (model-vertices)) 33)
  (check-equal? (here) center)
  (check-= (apply max
                  (map (lambda (vertex)
                         (point3-z (vertex-point vertex)))
                       (model-vertices)))
           1
           1e-12)

  ;; Orientation is restored along with position.
  (move forward 1)
  (check-= (point3-x (here)) 3 1e-12)
  (check-= (point3-y (here)) 1 1e-12))

(test-case "circular-shielded-reflector derives wall density from floor spacing"
  (reset-model!)
  ;; Floor radial spacing is 1, so height 1.1 produces two wall courses.
  (circular-shielded-reflector 4 11/10 8 2)
  (check-equal? (length (model-edges)) 64)
  (check-equal? (length (model-vertices)) 33))

(test-case "circular-shielded-reflector validates before drawing"
  (reset-model!)
  (check-exn exn:fail:contract?
             (lambda () (circular-shielded-reflector 0 1 8 2)))
  (check-exn exn:fail:contract?
             (lambda () (circular-shielded-reflector 4 0 8 2)))
  (check-exn exn:fail:contract?
             (lambda () (circular-shielded-reflector 4 1 2 2)))
  (check-exn exn:fail:contract?
             (lambda () (circular-shielded-reflector 4 1 8 0)))
  (check-exn exn:fail:contract?
             (lambda ()
               (circular-shielded-reflector
                4 1 8 2 #:wall-ringcount 0)))
  (check-equal? (model-edges) '()))
