#lang racket

(require rackunit
         racket/file
         (prefix-in m: manifold)
         "../antenna-turtle/main.rkt")

(define (m-point->list point)
  (list (m:point3-x point) (m:point3-y point) (m:point3-z point)))

(define (solid-bounds solid)
  (define-values (minimum maximum) (m:solid-bounds solid))
  (values (m-point->list minimum) (m-point->list maximum)))

(define (body-bounds body)
  (solid-bounds (solid-body-solid body)))

(define (check-point~= actual expected)
  (for ([actual-coordinate (in-list actual)]
        [expected-coordinate (in-list expected)])
    (check-= actual-coordinate expected-coordinate 1e-10)))

(for ([stl-format '(ascii binary)])
  (test-case (format "~a STL imports as a Manifold solid" stl-format)
    (define path (make-temporary-file "antenna-turtle-~a.stl"))
    (define source (m:cube 2 4 6 #:center? #t))
    (dynamic-wind
      (lambda () (m:write-stl source path #:format stl-format))
      (lambda ()
        (define imported (read-stl-solid path))
        (define-values (minimum maximum) (solid-bounds imported))
        (check-point~= minimum '(-1 -2 -3))
        (check-point~= maximum '(1 2 3))
        (m:solid-close! imported))
      (lambda ()
        (m:solid-close! source)
        (delete-file path)))))

(test-case "STL DSL placement follows with-scale and turtle anchoring"
  (reset-model!)
  (define path (make-temporary-file "antenna-turtle-~a.stl"))
  (define source (m:cube 2 4 6 #:center? #t))
  (dynamic-wind
    (lambda () (m:write-stl source path))
    (lambda ()
      (move forward 10)
      (define placed
        (with-scale millimeter
          (stl name imported path path anchor bottom)))
      (define-values (minimum maximum) (body-bounds placed))
      (check-point~= minimum '(9.999 -0.002 0))
      (check-point~= maximum '(10.001 0.002 0.006))
      (clear-bodies))
    (lambda ()
      (m:solid-close! source)
      (delete-file path))))
