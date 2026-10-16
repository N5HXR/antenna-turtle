#lang racket/base

(require "core.rkt"
         "solid-placement.rkt")

(provide
 (struct-out mesh-constraint)
 current-mesh-constraints
 model-mesh-constraints
 mesh-point
 add-mesh-plane
 clear-mesh-constraints)

;; User mesh constraints are solver-neutral scene annotations. A point locks
;; all three rectilinear coordinates. A plane retains its global normal so the
;; OpenEMS exporter can reject a plane that becomes oblique after automatic
;; one-port alignment instead of silently changing its meaning.
(struct mesh-constraint (kind point plane normal) #:transparent)

(define current-mesh-constraints (make-parameter '()))

(define (model-mesh-constraints)
  (current-mesh-constraints))

(define (current-position who)
  (transform-point (current-turtle-affine-transform who) '(0 0 0)))

(define (register-mesh-constraint! constraint)
  (current-mesh-constraints
   (append (current-mesh-constraints) (list constraint)))
  constraint)

(define (mesh-point)
  (register-mesh-constraint!
   (mesh-constraint 'point (current-position 'mesh-point) #f #f)))

(define plane-normals
  (hash 'xy (point3 0 0 1)
        'xz (point3 0 1 0)
        'yz (point3 1 0 0)))

(define (add-mesh-plane plane)
  (define normal (hash-ref plane-normals plane #f))
  (unless normal
    (raise-argument-error 'mesh-plane "(or/c 'xy 'xz 'yz)" plane))
  (register-mesh-constraint!
   (mesh-constraint 'plane (current-position 'mesh-plane) plane normal)))

(define (clear-mesh-constraints)
  (current-mesh-constraints '())
  (void))

(register-model-reset-hook! clear-mesh-constraints)
