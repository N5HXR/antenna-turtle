#lang antenna-turtle

(model
 title "40m Vertical With Loaded Radials"
 frequency 7.1
 ground real
 max-length {wavelength / 100})

(move up inch)
(with-scale 1.03
  (loop repeat 6 do
        (from-here
          (with-wire
            (move forward {quarter-wave / 4})
            (from-here (move right {quarter-wave / 16})
                       (turn right 90)
                       (move right {quarter-wave / 16}))
            (from-here (move left {quarter-wave / 16})
                       (turn left 90)
                       (move left {quarter-wave / 16}))
            ))
        (turn left 60))
  (with-wire (move up quarter-wave feed start)))

(show-model)
(display (format "Radial radius ~a m~n" {quarter-wave / 4}))

(define sweep (nec2c-vswr-sweep 3.5 14 #:steps 201))
(show-return-loss-sweep sweep)
(show-smith-chart sweep)
