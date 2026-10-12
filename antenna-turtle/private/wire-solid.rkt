#lang racket/base

(require racket/list
         racket/math
         (prefix-in m: manifold)
         "core.rkt"
         "solid-core.rkt")

(provide
 (struct-out wire-solid-derivation)
 call-with-derived-wire-scene)

;; A wire solid is deliberately derived rather than registered in the live
;; physical scene. NEC2C therefore keeps seeing the authoritative centerline
;; graph, while viewers and OpenEMS receive a temporary physical snapshot.
(struct wire-solid-derivation
  (body port edge-count feed-edge-id feed-gap radius segments)
  #:transparent)

(define identity-transform
  '((1 0 0 0)
    (0 1 0 0)
    (0 0 1 0)))

(define (point->list point)
  (list (point3-x point) (point3-y point) (point3-z point)))

(define (list+ first second)
  (map + first second))

(define (list- first second)
  (map - first second))

(define (list* value scale)
  (map (lambda (coordinate) (* coordinate scale)) value))

(define (dot first second)
  (for/sum ([a (in-list first)] [b (in-list second)]) (* a b)))

(define (cross a b)
  (list (- (* (second a) (third b))
           (* (third a) (second b)))
        (- (* (third a) (first b))
           (* (first a) (third b)))
        (- (* (first a) (second b))
           (* (second a) (first b)))))

(define (normalize who value)
  (define length (sqrt (dot value value)))
  (when (zero? length)
    (raise-arguments-error who "cannot normalize a zero-length vector"
                           "vector" value))
  (list* value (/ length)))

(define (edge-endpoints edge)
  (values (point->list (vertex-point (wire-edge-start edge)))
          (point->list (vertex-point (wire-edge-end edge)))))

(define (feed-center edge)
  (define-values (start stop) (edge-endpoints edge))
  (case (wire-edge-feed-location edge)
    [(start) start]
    [(center) (list* (list+ start stop) 1/2)]
    [(end) stop]))

(define (port-frame edge)
  (define-values (start stop) (edge-endpoints edge))
  (define direction (normalize 'openems-sweep (list- stop start)))
  ;; Choose a stable reference that is not nearly parallel with the wire.
  (define reference
    (if (< (abs (third direction)) 0.9) '(0 0 1) '(1 0 0)))
  (define transverse-u (normalize 'openems-sweep (cross reference direction)))
  (define transverse-v (normalize 'openems-sweep (cross direction transverse-u)))
  (values direction transverse-u transverse-v))

(define (frame-transform u v direction center)
  (list (list (first u) (first v) (first direction) (first center))
        (list (second u) (second v) (second direction) (second center))
        (list (third u) (third v) (third direction) (third center))))

(define (fresh-wire-name bodies sheets)
  (define used
    (append (map solid-body-name bodies) (map planar-sheet-name sheets)))
  (let loop ([index 1])
    (define candidate
      (if (= index 1) 'wire-network (string->symbol (format "wire-network-~a" index))))
    (if (member candidate used equal?) (loop (add1 index)) candidate)))

(define (make-capsule edge segments)
  (define-values (start stop) (edge-endpoints edge))
  (m:capsule start stop (/ (wire-edge-diameter edge) 2)
             #:segments segments))

(define (derive-wire-solid segments)
  (define edges (model-edges))
  (define feeds (filter wire-edge-feed? edges))
  (when (> (length feeds) 1)
    (raise-user-error
     'openems-sweep
     "the one-port OpenEMS backend accepts only one wire feed; found ~a"
     (length feeds)))
  (define capsules (map (lambda (edge) (make-capsule edge segments)) edges))
  (define joined
    (dynamic-wind
      void
      (lambda () (apply m:union capsules))
      (lambda () (for-each m:solid-close! capsules))))
  (if (null? feeds)
      (values joined #f #f)
      (let* ([feed-edge (first feeds)]
             [radius (/ (wire-edge-diameter feed-edge) 2)]
             [gap (max (/ (model-wavelength) 1000) radius)]
             [center (feed-center feed-edge)])
        (when (> gap (edge-length feed-edge))
          (eprintf
           (string-append
            "OpenEMS warning: derived feed gap ~a m exceeds wire edge ~a "
            "length ~a m; verify the physical feed geometry.\n")
           gap (wire-edge-id feed-edge) (edge-length feed-edge)))
        (define-values (direction u v) (port-frame feed-edge))
        ;; The subtractive slab is deliberately wider than every wire in the
        ;; network. The actual lumped port retains the feed wire's diameter.
        (define cut-width (* 2 (apply max (map wire-edge-diameter edges))))
        (define primitive (m:cube cut-width cut-width gap #:center? #t))
        (define cutter
          (dynamic-wind
            void
            (lambda ()
              (m:transform primitive (frame-transform u v direction center)))
            (lambda () (m:solid-close! primitive))))
        (define cut-solid
          (dynamic-wind
            void
            (lambda () (m:difference joined cutter))
            (lambda ()
              (m:solid-close! joined)
              (m:solid-close! cutter))))
        (define port
          (lumped-port
           (wire-edge-feed-name feed-edge)
           (model-impedance)
           (apply point3 center)
           (apply point3 direction)
           (apply point3 u)
           (apply point3 v)
           gap
           (wire-edge-diameter feed-edge)
           (wire-edge-diameter feed-edge)
           #f
           (frame-transform u v direction center)))
        (values cut-solid port
                (list feed-edge gap radius)))))

(define (call-with-derived-wire-scene procedure #:segments [segments 24])
  (unless (procedure? procedure)
    (raise-argument-error 'call-with-derived-wire-scene "procedure?" procedure))
  (unless (and (exact-integer? segments) (>= segments 3))
    (raise-argument-error 'call-with-derived-wire-scene "exact integer >= 3" segments))
  (define edges (model-edges))
  (if (null? edges)
      (procedure #f)
      (let ()
        (define original (current-solid-scene))
        (define-values (solid derived-port feed-data)
          (derive-wire-solid segments))
        (define body
          (solid-body
           (fresh-wire-name (solid-scene-bodies original)
                            (solid-scene-sheets original))
           pec solid 20 'world identity-transform #f))
        (define combined
          (solid-scene
           (append (solid-scene-bodies original) (list body))
           (solid-scene-sheets original)
           (append (solid-scene-ports original)
                   (if derived-port (list derived-port) '()))
           (solid-scene-components original)))
        (define derivation
          (wire-solid-derivation
           body derived-port (length edges)
           (and feed-data (wire-edge-id (first feed-data)))
           (and feed-data (second feed-data))
           (and feed-data (third feed-data))
           segments))
        (dynamic-wind
          void
          (lambda ()
            (parameterize ([current-solid-scene combined])
              (procedure derivation)))
          (lambda () (m:solid-close! solid))))))
