#lang antenna-turtle

(model
 title "80m Inverted Vee"
 frequency 3.6
 ground real
 max-length {wavelength / 100})

(move up {65 * feet})
(wire-port feedpoint forward gap inch)
(coax type rg58
      output feedpoint
      (move down {64 * feet})
      (move left {40 * feet}))

(loop repeat 2 do
      (from-here
        (move forward (half inch))
        (turn down {90 - 48})
        (with-wire (move forward {67 * feet})))
      (turn left 180))

(show-model)
        
(define sweep (nec2c-vswr-sweep 1.75 7 #:steps 301))
(show-return-loss-sweep sweep)
(show-smith-chart sweep)
