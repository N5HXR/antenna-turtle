#lang antenna-turtle

(require (prefix-in m: manifold))

;; Lossy companion to filter-test.rkt.  FR4 loss is referenced to the model
;; frequency, copper has 35 um physical thickness, and the optional enclosure
;; exercises the revision-1 rectilinear solid-conductor path.
(model title "OpenEMS lossy hybrid lumped/distributed bandpass"
       frequency 435
       impedance 50)

(define board-length 250)
(define board-width 60)
(define substrate-height 1.6)
(define trace-width 3)
(define coupling-gap 1)
(define resonator-length 169)
(define feed-length 20)
(define resonator-gap 4)
(define copper-thickness 0.035)
(define fr4 (dielectric name fr4 er 4.4 loss-tangent 0.002))
(define capacitors {2.2 * picofarads})

(define shield-solid
  (m:translate
   (m:difference
    (m:cube board-length board-width 12)
    (m:translate
     (m:cube (- board-length 4) (- board-width 4) 10)
     (list 2 2 0)))
   (list (- (half board-length)) (- (half board-width)) 0)))

(define (trace-at name center length)
  (from-here
    (move forward center up substrate-height)
    (add-rect-sheet name length trace-width
                    #:material copper
                    #:thickness copper-thickness
                    #:precedence 20
                    #:mesh-edges 'metal)))

(with-scale millimeters
  (with-material fr4
    (cuboid name substrate
      size (list board-length board-width substrate-height)
      anchor bottom))
  (sheet rect name ground
    size (list board-length board-width)
    material copper
    thickness copper-thickness
    precedence 20)

  (define resonator-half (/ resonator-length 2))
  (define left-gap-center (- (+ resonator-half (/ coupling-gap 2))))
  (define right-gap-center (+ resonator-half (/ coupling-gap 2)))

  (from-here
    (move right resonator-gap)
    (trace-at 'resonator 0 resonator-length)
    (trace-at 'input-feed
              (- left-gap-center (/ coupling-gap 2) (/ feed-length 2))
              feed-length)
    (from-here
      (move forward left-gap-center up (+ substrate-height 0.5))
      (lumped-element forward
        name input-coupling
        capacitance capacitors
        gap coupling-gap
        size (list trace-width 1)))
    (from-here
      (move forward (- left-gap-center (/ coupling-gap 2) feed-length)
            up (/ substrate-height 2))
      (port up name input gap substrate-height size '(2 2))))

  (from-here
    (move left resonator-gap)
    (trace-at 'resonator2 0 resonator-length)
    (trace-at 'output-feed
              (+ right-gap-center (/ coupling-gap 2) (/ feed-length 2))
              feed-length)
    (from-here
      (move forward right-gap-center up (+ substrate-height 0.5))
      (lumped-element forward
        name output-coupling
        capacitance capacitors
        gap coupling-gap
        size (list trace-width 1)))
    (from-here
      (move forward (+ right-gap-center (/ coupling-gap 2) feed-length)
            up (/ substrate-height 2))
      (port up name output gap substrate-height size '(2 2))))

  ;; Comment this body out to isolate board loss from enclosure loss/loading.
  ;(body name shield
  ;  geometry shield-solid
  ;  material aluminum
  ;  metal-thickness 2
  ;  precedence 100)
  )

(show-solid-model)

(when #f
  (define long-standard
    (derive-simulation-profile
     standard #:name 'long-draft #:maximum-timesteps 1000000))
  
  (define result
    (simulate engine openems
              sweep '(350 520)
              profile long-standard
              keep-artifacts #t))

  (show-smith-chart result)

  (show-s-parameter-magnitude result)

  (define budget (power-budget result))

  (display-power-budget budget)

  )
