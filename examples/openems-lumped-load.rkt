#lang antenna-turtle

;; A one-port 50-ohm microstrip dummy load. The resistor is an ideal OpenEMS
;; lumped region connecting the end of the trace to the ground plane.
(model title "OpenEMS microstrip dummy load"
       frequency 915
       impedance 50)

(define board-length 60)
(define board-width 30)
(define substrate-height 1.6)
(define trace-length 45)
(define trace-width 3)
(define fr4 (dielectric name lossless-fr4 er 4.4))

(with-scale millimeters
  (with-material fr4
    (cuboid name substrate
      size (list board-length board-width substrate-height)
      anchor bottom))

  (sheet rect name ground
    size (list board-length board-width)
    precedence 20)

  (from-here
    (move up substrate-height)
    (sheet rect name trace
      size (list trace-length trace-width)
      precedence 20
      mesh-edges metal))

  (from-here
    (move backward (/ trace-length 2) up (/ substrate-height 2))
    (port up
      name input
      gap substrate-height
      size (list trace-width trace-width)))

  (from-here
    (move forward (/ trace-length 2) up (/ substrate-height 2))
    (lumped-element up
      name termination
      resistance {50 * ohms}
      gap substrate-height
      size (list trace-width trace-width))))

(show-solid-model)

(when #f
  (define result
    (simulate engine openems
              sweep '(800 1050)
              profile draft
              keep-artifacts #t))
  
  (show-return-loss-sweep result)
  (show-impedance-sweep result)
  (show-smith-chart result)
  )
