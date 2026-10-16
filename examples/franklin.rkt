#lang antenna-turtle

(model title "Meshtastic Franklin Array"
       max-length (* 3 millimeters)
       impedance 200
       frequency 915)

;; Antenna design parameters.
(define element-count 1)

;; Empirically determined tuning parameters.
(define tune-stub 0.94)
(define tune-scale 1.01)

;; Franklin arrays use tuning stubs to align collinear elements.
(define stub-length (* tune-stub quarter-wave))
(define stub-width centimeter)

;; Construct a Franklin array.
(with-scale tune-scale
  (with-wire (spread up half-wave feed center))
  (reflect up
    (move up quarter-wave)
    (with-wire
      (loop repeat element-count do
	    (move left stub-length)
	    (move up stub-width)
	    (move right stub-length)
	    (move up half-wave)))))

;(define impedance (nec2c-measure-impedance))
(define sweep (nec2c-vswr-sweep 200 2000 #:steps 601))
(define azimuth (nec2c-azimuth-pattern #:elevation 0 #:step 2))
(define sphere (nec2c-radiation-grid #:theta-step 1 #:phi-step 1))

(show-radiation-pattern-opengl sphere #:palette 'electric)
(show-return-loss-sweep sweep)
;(export-mmana "../mmana/franklin.maa")

(display (format "Gain: ~a ~n" (maximum-gain sphere)))
(display (format "Imp:  ~a ~n" (impedance-at sweep 906 #:interpolate? #t)))
(display (format "RL:   ~a ~n" (return-loss-at sweep 906 #:interpolate? #t)))
(display (format "VSWR: ~a ~n" (vswr-at sweep 906 #:interpolate? #t)))

(show-return-loss-sweep sweep)
