#lang antenna-turtle

(define (yagi drv-len ref-len ref-pos)
  (reset-model!)
  (model
   title "A Yagi"
   frequency 915
   wire-diameter (* 0.125 inch))
  (with-wire (spread left (* drv-len wavelength) feed center))
  (from-here
    (move back (* ref-pos wavelength))
    (with-wire (spread left (* ref-len wavelength)))))

(yagi (* 1.0 0.5)
      (* 1.05 0.5)
      (* 1.0 0.2))

(show-model)

(define cases
  (loop for i from 1.0 to 1.45 by 0.05
        for drv-len = (* 0.88 0.5)
        for ref-len = (* 1.02 drv-len)
        for ref-pos = (* i 0.2)
        collect
        (begin
          (yagi drv-len ref-len ref-pos)
          (display (format "Pos: ~a, Imp: ~a~n" i
                           (nec2c-feedpoint-sample-impedance
                            (first
                             (nec2c-impedance-result-samples
                              (nec2c-measure-impedance))))))
          (radiation-case
           (format "Len = ~a" i)
           (nec2c-radiation-grid)))))

(show-radiation-comparison cases #:aspect-ratio 16/9 #:palette 'mmana #:scale 'arrl)

; (show-radiation-pattern-opengl pattern #:palette 'electric)

(define sweep
  (nec2c-vswr-sweep 850 1000 #:steps 51))

(define imp (nec2c-measure-impedance))

(show-vswr-sweep sweep)

(show-impedance-sweep sweep)
