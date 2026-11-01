#lang antenna-turtle

(model
 title "20m Caged Dipole"
 frequency 14.1
 ground real)

(move up half-wave)
(with-scale 0.92
  (with-wire (spread forward inch feed center))

  (loop repeat 2 do
        (from-here
          (move forward (half inch))
          (loop repeat 6 do
                (from-here
                  (with-wire
                    (turn left 45)
                    (move forward foot)
                    (turn right 45)
                    (move forward {quarter-wave - (1.414 * foot)})
                    (turn right 45)
                    (move forward foot)))
                (turn roll-left 60)))
        (turn left 180)))

(show-model)

(define sweep (nec2c-vswr-sweep 7 28 #:steps 301))
(define pattern (nec2c-radiation-grid))
(show-return-loss-sweep sweep)
(show-smith-chart sweep)
(show-radiation-pattern-opengl pattern #:palette 'electric)
(html-auto-report "9.9-cage-dipole.html")
