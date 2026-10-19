#lang racket/base

(require racket/file
         racket/math
         racket/path
         racket/promise
         racket/runtime-path
         "core.rkt"
         "export-common.rkt")

(provide export-nec2c
         write-nec2c-deck
         last-nec2c-export-path
         nec2c-feed-segment)

(define last-export (box #f))
(define-runtime-module-path nec2c-surface-module "nec2c-surface.rkt")

;; Keep the wire-only language usable without the optional native Manifold
;; dependency.  When available, this module supplies refined MFIE patches and
;; rigidly translated wire coordinates for closed PEC surface bodies.
(define surface-api
  (delay
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (for/hash ([name
                  (in-list
                   '(model-nec2c-surface-geometry
                     nec2c-surface-geometry-patches
                     nec2c-surface-geometry-attachments
                     nec2c-surface-patch-center
                     nec2c-surface-patch-normal
                     nec2c-surface-patch-area
                     nec2c-surface-patch-corners
                     nec2c-adjusted-edge-point))])
        (values name (dynamic-require nec2c-surface-module name))))))

(define (surface-call name . arguments)
  (define api (force surface-api))
  (and api (apply (hash-ref api name) arguments)))

(define (last-nec2c-export-path)
  (define value (unbox last-export))
  (and value
       (eq? (car value) (current-antenna-model))
       (cdr value)))

(define (export-z z)
  (define translated (+ z (model-height)))
  (if (and (model-grounded?)
           (<= (abs translated) (snap-length)))
      0
      translated))

(define (pcoord who point accessor)
  (coordinate-string who (accessor point)))

(define (pcoord-z who point)
  (coordinate-string who (export-z (point3-z point))))

(define (validate-ground-geometry! who [surface-geometry #f])
  (when (model-grounded?)
    (for ([edge (in-list (model-edges))])
      (define start-z
        (export-z
         (point3-z (edge-export-point surface-geometry edge 'start))))
      (define end-z
        (export-z
         (point3-z (edge-export-point surface-geometry edge 'end))))
      (when (or (negative? start-z) (negative? end-z))
        (raise-arguments-error
         who
         "grounded NEC geometry may not extend below Z=0"
         "wire" (wire-edge-id edge)
         "start Z" start-z
         "end Z" end-z))
      (when (and (zero? start-z) (zero? end-z))
        (raise-arguments-error
         who
         "a NEC wire may not lie in the ground plane"
         "wire" (wire-edge-id edge))))
    (when surface-geometry
      (for* ([patch
              (in-list
               (surface-call
                'nec2c-surface-geometry-patches surface-geometry))]
             [corner
              (in-list (surface-call 'nec2c-surface-patch-corners patch))])
        (define z (export-z (point3-z corner)))
        (when (negative? z)
          (raise-arguments-error
           who
           "grounded NEC surface geometry may not extend below Z=0"
           "patch corner" corner
           "exported Z" z))))))

(define (write-ground-card out who)
  (define ground (model-ground))
  (case (ground-spec-kind ground)
    [(none) (void)]
    [(perfect) (displayln "GN 1" out)]
    [(real)
     (fprintf out "GN 2 0 0 0 ~a ~a\n"
              (coordinate-string who
                                 (ground-spec-relative-permittivity ground))
              (coordinate-string who (ground-spec-conductivity ground)))]))

(define (nec2c-feed-segment edge max-length)
  (define count (edge-segment-count edge max-length))
  (case (wire-edge-feed-location edge)
    [(start) 1]
    [(center) (quotient (add1 count) 2)]
    [(end) count]
    [else
     (raise-arguments-error
      'nec2c-feed-segment "edge does not contain a feed" "edge" edge)]))

(define (feed-voltage edge)
  (define magnitude (wire-edge-feed-amplitude edge))
  (define radians (degrees->radians (wire-edge-feed-phase edge)))
  (make-rectangular (* magnitude (cos radians))
                    (* magnitude (sin radians))))

(define radians->degrees-factor (/ 180 pi))

(define (write-surface-patches out who surface-geometry)
  (when surface-geometry
    (for ([patch
           (in-list
            (surface-call 'nec2c-surface-geometry-patches surface-geometry))])
      (define center (surface-call 'nec2c-surface-patch-center patch))
      (define normal (surface-call 'nec2c-surface-patch-normal patch))
      (define elevation
        (* radians->degrees-factor (asin (max -1 (min 1 (point3-z normal))))))
      (define azimuth
        (if (and (zero? (point3-x normal)) (zero? (point3-y normal)))
            0
            (* radians->degrees-factor
               (atan (point3-y normal) (point3-x normal)))))
      ;; Arbitrary-shape SP patches retain precisely the centroid, outward
      ;; normal, and area that NEC uses.  At a wire junction NEC assumes the
      ;; patch is square and subdivides it into four connection patches.
      (fprintf out "SP 0 0 ~a ~a ~a ~a ~a ~a\n"
               (pcoord who center point3-x)
               (pcoord who center point3-y)
               (pcoord-z who center)
               (coordinate-string who elevation)
               (coordinate-string who azimuth)
               (coordinate-string
                who (surface-call 'nec2c-surface-patch-area patch))))))

(define (edge-export-point surface-geometry edge end)
  (if surface-geometry
      (surface-call 'nec2c-adjusted-edge-point surface-geometry edge end)
      (vertex-point
       ((if (eq? end 'start) wire-edge-start wire-edge-end) edge))))

(define (write-nec2c-deck out [analysis-cards '()])
  (define who 'export-nec2c)
  (define max-length (require-segmentation! who))
  (define surface-candidate
    (surface-call 'model-nec2c-surface-geometry))
  (define surface-geometry
    (and surface-candidate
         (pair?
          (surface-call
           'nec2c-surface-geometry-patches surface-candidate))
         surface-candidate))
  (validate-ground-geometry! who surface-geometry)
  (fprintf out "CM ~a\n" (model-title))
  (fprintf out "CM Generated by antenna-turtle; coordinates are meters\n")
  (when surface-geometry
    (fprintf out "CM ~a NEC2 MFIE surface patches; ~a wire attachments\n"
             (length
              (surface-call
               'nec2c-surface-geometry-patches surface-geometry))
             (length
              (surface-call
               'nec2c-surface-geometry-attachments surface-geometry))))
  (fprintf out "CE\n")
  (write-surface-patches out who surface-geometry)
  (for ([edge (in-list (model-edges))])
    (define a (edge-export-point surface-geometry edge 'start))
    (define b (edge-export-point surface-geometry edge 'end))
    (define count (edge-segment-count edge max-length))
    (fprintf out
             "GW ~a ~a ~a ~a ~a ~a ~a ~a ~a\n"
             (wire-edge-id edge)
             count
             (pcoord who a point3-x)
             (pcoord who a point3-y)
             (pcoord-z who a)
             (pcoord who b point3-x)
             (pcoord who b point3-y)
             (pcoord-z who b)
             (coordinate-string who (/ (wire-edge-diameter edge) 2))))
  ;; GE 1 makes wire endpoints at Z=0 connect to their ground-plane image.
  ;; Free-space geometry deliberately retains GE 0.
  (fprintf out "GE ~a\n" (if (model-grounded?) 1 0))
  (write-ground-card out who)
  (for ([edge (in-list (model-edges))]
        #:when (wire-edge-feed? edge))
    (define voltage (feed-voltage edge))
    (fprintf out "EX 0 ~a ~a 0 ~a ~a\n"
             (wire-edge-id edge)
             (nec2c-feed-segment edge max-length)
             (coordinate-string who (real-part voltage))
             (coordinate-string who (imag-part voltage))))
  (for ([card (in-list analysis-cards)])
    (unless (string? card)
      (raise-argument-error 'write-nec2c-deck "string?" card))
    (displayln card out))
  (fprintf out "EN\n"))

(define (export-nec2c path)
  (validate-model!)
  (call-with-output-file path
    #:exists 'truncate/replace
    (lambda (out) (write-nec2c-deck out)))
  (set-box! last-export
            (cons (current-antenna-model)
                  (simplify-path (path->complete-path path))))
  path)
