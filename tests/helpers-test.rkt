#lang racket

(require rackunit
         "../antenna-turtle/main.rkt")

(define (distance-from point center)
  (sqrt (+ (sqr (- (point3-x point) (point3-x center)))
           (sqr (- (point3-y point) (point3-y center)))
           (sqr (- (point3-z point) (point3-z center))))))

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
