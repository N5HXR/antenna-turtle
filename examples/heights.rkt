#lang antenna-turtle

(model title "Heights"
       frequency 7.1
       ground perfect)

(define (antenna wls)
  (clear-wires)
  (move up {wls * wavelength})
  (with-wire (spread forward half-wave feed center)))

(define (sample wls)
  (antenna wls)
  (define pattern (nec2c-radiation-grid #:theta-step 1 #:phi-step 1))
  (radiation-case
   (format "~a * WL" wls) pattern))

(define cases
  (loop for i in '(1/8 2/8 3/8 4/8 5/8 6/8 7/8 1) collect
        (sample i)))

(show-radiation-cut-comparison
 cases
 #:cut 'elevation
 #:azimuth 90
 #:floor-db -10
 #:scale 'absolute)

;(show-radiation-comparison #:palette 'magma cases #:scale 'db)
