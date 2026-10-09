#lang antenna-turtle

(require (prefix-in m: manifold))

;; A compact one-port microstrip reference for the dielectric-and-sheet
;; OpenEMS milestone. The dimensions are a starting point, not a tuned design.
(model title "OpenEMS 915 MHz lossless-substrate patch"
       frequency 915
       impedance 50)

(define substrate-width 0.15)
(define substrate-length 0.15)
(define substrate-height 0.0016)
(define patch-width 0.108)
(define patch-length 0.083)
(define feed-offset-x -0.020)
(define feed-size 0.002)

(define substrate-material
  (dielectric #:name 'lossless-fr4
              #:relative-permittivity 4.4))

(define raw-substrate
  (m:cube substrate-width substrate-length substrate-height))
(define centered-substrate
  (m:translate raw-substrate
               (list (- (/ substrate-width 2))
                     (- (/ substrate-length 2))
                     0)))
(m:solid-close! raw-substrate)

(body substrate
  geometry centered-substrate
  material substrate-material
  priority 10)

(sheet ground-plane
  points `((,(- (/ substrate-width 2)) ,(- (/ substrate-length 2)))
           (,(+ (/ substrate-width 2)) ,(- (/ substrate-length 2)))
           (,(+ (/ substrate-width 2)) ,(+ (/ substrate-length 2)))
           (,(- (/ substrate-width 2)) ,(+ (/ substrate-length 2))))
  material pec
  priority 20)

(move up substrate-height)
(sheet patch
  points `((,(- (/ patch-width 2)) ,(- (/ patch-length 2)))
           (,(+ (/ patch-width 2)) ,(- (/ patch-length 2)))
           (,(+ (/ patch-width 2)) ,(+ (/ patch-length 2)))
           (,(- (/ patch-width 2)) ,(+ (/ patch-length 2))))
  material pec
  priority 20)

;; The feed spans from ground to patch. Position the turtle at its center.
(move down (/ substrate-height 2)
      forward feed-offset-x)
(port up
  name "feed"
  impedance 50
  gap substrate-height
  width feed-size
  depth feed-size)

;; Scene registration owns its transformed copy.
(m:solid-close! centered-substrate)

;; Inspect before committing to the solver run if desired:
;; (show-solid-model)

(define result
  (openems-sweep 800 1050
                 #:steps 101
                 #:keep-artifacts? #t))

(show-return-loss-sweep result)
(show-impedance-sweep result)
(show-smith-chart result)

(define pattern (openems-radiation-grid result))
(show-radiation-pattern-opengl pattern #:palette 'inferno)
