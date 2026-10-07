#lang antenna-turtle

(define impedance
  (nec2c-measure-impedance))

(define sweep
  (nec2c-vswr-sweep 440 450 #:steps 51))

(define azimuth
  (nec2c-azimuth-pattern #:elevation 0 #:step 2))

(define sphere
  (nec2c-radiation-grid #:theta-step 5 #:phi-step 5))

(show-vswr-sweep sweep)
(show-radiation-cut azimuth)
(show-radiation-pattern-3d sphere)
