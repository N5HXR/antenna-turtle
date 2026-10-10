#lang racket/base

(require racket/file
         racket/list
         racket/match
         racket/port
         racket/string
         (prefix-in m: manifold)
         "solid-core.rkt"
         "solid-primitives.rkt")

(provide read-stl-solid add-stl-body)

(define number-pattern
  "[-+]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][-+]?[0-9]+)?")
(define vertex-pattern
  (pregexp
   (string-append
    "^\\s*vertex\\s+(" number-pattern ")\\s+(" number-pattern
    ")\\s+(" number-pattern ")\\s*$")))

(define (indexed-mesh vertices-by-face)
  (define indices (make-hash))
  (define vertices '())
  (define next-index 0)
  (define (vertex-index coordinates)
    (hash-ref!
     indices coordinates
     (lambda ()
       (define index next-index)
       (set! next-index (add1 next-index))
       (set! vertices (cons (apply m:point3 coordinates) vertices))
       index)))
  (define triangles
    (for/list ([face (in-list vertices-by-face)])
      (match-define (list a b c) face)
      (m:triangle (vertex-index a) (vertex-index b) (vertex-index c))))
  (m:mesh (list->vector (reverse vertices)) (list->vector triangles)))

(define (binary-stl? data)
  (and (>= (bytes-length data) 84)
       (let* ([count (integer-bytes->integer data #f #f 80 84)]
              [expected (+ 84 (* count 50))])
         (= expected (bytes-length data)))))

(define (binary-real data offset)
  (floating-point-bytes->real data #f offset (+ offset 4)))

(define (binary-faces data)
  (define count (integer-bytes->integer data #f #f 80 84))
  (for/list ([index (in-range count)])
    (define triangle-start (+ 84 (* index 50)))
    ;; Skip the stored normal; Manifold derives topology from the vertices.
    (for/list ([vertex (in-range 3)])
      (define start (+ triangle-start 12 (* vertex 12)))
      (for/list ([coordinate (in-range 3)])
        (binary-real data (+ start (* coordinate 4)))))))

(define (ascii-faces data)
  (define vertices
    (reverse
     (for/fold ([found '()]) ([line (in-lines (open-input-bytes data))])
       (define match (regexp-match vertex-pattern line))
       (if match (cons (map string->number (cdr match)) found) found))))
  (unless (and (pair? vertices) (zero? (remainder (length vertices) 3)))
    (raise-user-error
     'read-stl-solid "ASCII STL does not contain complete triangular facets"))
  (for/list ([offset (in-range 0 (length vertices) 3)])
    (take (drop vertices offset) 3)))

(define (read-stl-solid path)
  (unless (path-string? path)
    (raise-argument-error 'read-stl-solid "path-string?" path))
  (define data (file->bytes path))
  (define faces
    (if (binary-stl? data) (binary-faces data) (ascii-faces data)))
  (m:mesh->solid (indexed-mesh faces)))

(define (add-stl-body name path
                      #:material [material (current-solid-material)]
                      #:precedence [precedence #f]
                      #:anchor [anchor 'center])
  (define source (read-stl-solid path))
  (dynamic-wind
    void
    (lambda ()
      (add-body name material source
                #:precedence
                (or precedence (material-default-precedence material))
                #:anchor anchor))
    (lambda ()
      (unless (m:solid-closed? source) (m:solid-close! source)))))
