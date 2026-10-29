#lang racket

(require rackunit
         racket/string
         "../antenna-turtle/main.rkt"
         (only-in "../antenna-turtle/private/export-nec2c.rkt"
                  write-nec2c-deck))

(define (point-values point)
  (list (point3-x point) (point3-y point) (point3-z point)))

(define (point-delta adjusted original)
  (map - (point-values adjusted) (point-values original)))

(define integration-executable
  (or (getenv "NEC2C")
      (find-executable-path "nec2c")))

(test-case "cuboid unions become regular NEC patches and translate attached wires rigidly"
  (reset-model!)
  (model-frequency 240)
  (model-ground (real-ground 13 0.005))
  (maximum-nec2c-patch-length 0.3)
  (with-body name fixture form surface material pec anchor origin
    (from-here
      (move up 0.5)
      (cuboid size '(2 1 1)))
    (from-here
      (move forward 1.25)
      (move up 0.5)
      (cuboid size '(1 1 1))))
  (from-here
    (move up 1)
    (turn up 90)
    (with-wire
      (move forward 0.5 feed start)
      (move forward 0.25)))
  (define geometry (model-nec2c-surface-geometry))
  (define patches (nec2c-surface-geometry-patches geometry))
  (check-true (pair? patches))
  (check-true
   (for/and ([patch (in-list patches)])
     (= (length (nec2c-surface-patch-corners patch)) 4)))
  (check-equal? (length (nec2c-surface-geometry-attachments geometry)) 1)
  (define first-edge (first (model-edges)))
  (define last-edge (last (model-edges)))
  (define first-original (vertex-point (wire-edge-start first-edge)))
  (define last-original (vertex-point (wire-edge-end last-edge)))
  (define first-adjusted (nec2c-adjusted-edge-point geometry first-edge 'start))
  (define last-adjusted (nec2c-adjusted-edge-point geometry last-edge 'end))
  (for ([left (in-list (point-delta first-adjusted first-original))]
        [right (in-list (point-delta last-adjusted last-original))])
    (check-= left right 1e-12))
  (define deck (open-output-string))
  (write-nec2c-deck deck)
  (define text (get-output-string deck))
  (check-true (string-contains? text "NEC2 MFIE surface patches"))
  (check-true (string-contains? text "SP 0 0"))
  (check-true (string-contains? text "GN 2 0 0 0 13"))
  (clear-bodies))

(when integration-executable
  (test-case "automatic near-field bounds include PEC surfaces and stop at ground"
    (reset-model!)
    (model-frequency 300)
    (model-ground (real-ground 13 0.005))
    (maximum-segment-length 0.05)
    (maximum-nec2c-patch-length 0.5)
    (with-body name bounds-fixture form surface material pec anchor origin
      (from-here
        (move up 0.5)
        (cuboid size '(4 1 1))))
    (from-here
      (move up 1)
      (turn up 90)
      (with-wire
        (move forward 0.5 feed start)))
    ;; A disabled dielectric still participates in the sampling envelope so
    ;; loaded and reference runs remain directly comparable.
    (define bounds-foam (dielectric name bounds-foam er 2.5))
    (from-here
      (move forward 6)
      (move up 0.5)
      (cuboid name distant-dielectric
              size '(1 1 1)
              material bounds-foam))
    (nec2c-executable integration-executable)
    (define fields
      (nec2c-near-field-planes
       #:dielectrics? #f
       #:planes
       (list
        (near-field-section
         #:plane 'y #:samples '(2 2) #:fields '(electric)))))
    (define section (first (nec2c-near-field-result-sections fields)))
    (define x-values (nec2c-near-field-section-u-values section))
    (define z-values (nec2c-near-field-section-v-values section))
    ;; The dielectric extends to X=6.5 m. At 300 MHz, its automatic margin
    ;; should be nearly another metre, symmetrically about the feed centroid.
    (check-true (< (first x-values) -7.4))
    (check-true (> (last x-values) 7.4))
    ;; A grounded model samples only NEC's physical upper half-space.
    (check-equal? (first z-values) 0)
    (check-true (> (last z-values) 2.4))
    (clear-bodies)))

(test-case "axis alignment is local to the enclosing body frame"
  (reset-model!)
  (model-frequency 240)
  (maximum-nec2c-patch-length 0.4)
  (turn left 27)
  (with-body name rotated form surface material pec anchor origin
    (cuboid size '(2 1 0.5)))
  (check-not-exn model-nec2c-surface-geometry)
  (check-true
   (pair?
    (nec2c-surface-geometry-patches (model-nec2c-surface-geometry))))
  (clear-bodies))
