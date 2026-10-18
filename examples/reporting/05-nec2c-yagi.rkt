#lang antenna-turtle

;; A wire-native portable-report example.  The network sweep and angular grid
;; remain independent NEC2C analyses; the report combines their retained
;; numerical results with the current Antenna Turtle geometry.
(model title "Three-element Yagi NEC2C report"
       frequency 150.0
       max-length (/ wavelength 100)
       wire-diameter (* 6 millimeter))

(define element-layout
  (list (list 'reflector 0 (* 0.52 wavelength))
        (list 'driven (* 1/5 wavelength) (* 0.48 wavelength))
        (list 'director (* 2/5 wavelength) (* 0.45 wavelength))))

(define (element role boom-position length)
  (from-here
    (move forward boom-position)
    (when (eq? role 'driven) (feed center))
    (with-wire (spread right length))))

(loop for (role boom-position length) in element-layout
      do (element role boom-position length))

(define sweep (nec2c-vswr-sweep 120 180 #:steps 121))
(define pattern
  (nec2c-radiation-grid #:frequency 150 #:theta-step 3 #:phi-step 3))

(write-html-report
 sweep
 "scratch/html-report-nec2c-yagi.html"
 #:pattern pattern)
