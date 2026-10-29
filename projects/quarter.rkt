#lang antenna-turtle

(model title "Quarter Wave Test"
       frequency 1296
       ground perfect)

(define short-unit {0.707 * quarter-wave / 4})
(define long-unit (* short-unit (sqrt 2)))
(define mast-len {wavelength * 0.73})
(define (slope x y)
  (* -1
     (/ (+ x y) (sqrt 2))
     (tan (/ pi 4))))

(move up mast-len)
(with-scale {0.995 * 1144 / 1296}
  (loop repeat 4 do
        (turn left 90)
        (with-surface slope
          (loop for row from 1 to 5 do
                (from-here
                  (move forward {row * short-unit})
                  (turn left {180 - 45})
                  (with-wire
                    (loop for i from 1 to row do
                          (move forward long-unit))
                    (turn left {180 - 45})
                    (loop for i from 1 to row do
                          (move forward short-unit)
                          (turn left 90)
                          (when (< i row) (move forward short-unit))
                          (turn right 90)))))))
  (turn up 90)
  (from-here
    (with-wire (move forward quarter-wave feed start))))

; simulate an RG402 "mast" holding up the antenna to match the physical build
(with-wire (move back mast-len))

(show-model)

(define sweep (nec2c-vswr-sweep 1000 1600 #:steps 101))
(define pattern
  (nec2c-radiation-grid #:frequency 1296 #:theta-step 2 #:phi-step 2))

(show-return-loss-sweep sweep)

;(write-html-report
; sweep
; "html-report-quarter.html"
; #:pattern pattern)
