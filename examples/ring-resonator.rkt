#lang antenna-turtle

(model
 title "Ring resonator"
 frequency 717)

(define fr4 (dielectric name fr4 er 4.4 loss-tangent 0.015))
(define board-length 80)
(define board-width 80)
(define board-thick 1.6)
(define board-size (list board-length board-width board-thick))
(define ground-size (list board-length board-width))
(define seg 32.7) ;;; (/ wavelength 10.0 millimeters))

(display (format "seg is ~a ~n" seg))

(define (resonator-arm)
  (port up gap board-thick size '(3 3))
  (move up (half board-thick))
  ;; Names are intentionally omitted: repeated geometry receives stable,
  ;; scene-local identities while the measured ports retain useful labels.
  (with-traces 3
    material copper
    thickness 0.035
    precedence 30
    (move forward 10))
  (move forward 0.5)
  (from-here
    (move up 0.5)
    (lumped-element forward
      capacitance (* 5.6 picofarads) gap 3 size '(3 1)))
  (move forward 0.5)
  (with-traces 3
    material copper
    thickness 0.035
    precedence 30
    (move forward seg)
    (turn left 90)
    (move forward seg)
    (turn left 90)
    (move forward seg)
    ))

(with-scale millimeters
  ;; PCB construction
  (sheet rect name ground size ground-size material copper thickness 0.035 mesh-edges metal)
  (with-material fr4
    (cuboid name substrate
      size (list board-length board-width board-thick)
      anchor bottom))

  (move right 11)

  ;; port
  (move back 7)
  (from-here
    (move right (half seg))
    (move back 20 up (half board-thick))
    (resonator-arm))

  ;; port
  (from-here
    (move left (half seg))
    (move forward 34 up (half board-thick) left 25)
    (turn left 180)
    (resonator-arm))
  )

(show-solid-model)

(when #f
  (define long-draft
    (derive-simulation-profile
     draft #:name 'long-draft #:maximum-timesteps 1000000 #:frequency-steps 301))

  (define result
    (simulate engine openems
              sweep '(200 2400)
              profile long-draft
              keep-artifacts #t))

  (show-s-parameter-magnitude result)

  (show-smith-chart result)

  (define budget (power-budget result #:frequency 717))

  (display-power-budget budget)

  )
