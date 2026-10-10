#lang antenna-turtle

;; The same one-port microstrip idea as openems-patch.rkt, expressed through
;; the turtle-oriented solid API. Geometry dimensions in this scope are mm;
;; simulation results and imported/generated Manifold geometry remain SI.
(model title "OpenEMS 915 MHz patch — solid DSL"
       frequency 915
       impedance 50)

(define substrate-size '(150 150 1.6))
(define patch-size '(99 77))
(define substrate-height 1.6)
(define feed-offset -16)

(define fr4 (dielectric name lossless-fr4 er 4.4))

(with-scale millimeters
  (with-material fr4
    (cuboid substrate
      size substrate-size
      anchor bottom))

  (sheet rect ground-plane
    size (take substrate-size 2)
    mesh-edges exact)

  (from-here
    (move up substrate-height)
    (sheet rect patch
      size patch-size
      mesh-edges metal))

  ;; Ports are subordinate features placed in the turtle frame. Explicit
  ;; dimensions scale with the enclosing geometry scope.
  (from-here
    (move up (/ substrate-height 2)
          left feed-offset)
    (port up
      name feed
      gap substrate-height
      size '(2 2))))

(show-solid-model)

(define result
  (simulate engine openems
            sweep '(800 1050)
            profile draft
            keep-artifacts #t))

(show-return-loss-sweep result)
(show-impedance-sweep result)
(show-smith-chart result)

(define pattern (radiation-pattern result))
(show-radiation-pattern-opengl pattern #:palette 'electric)
