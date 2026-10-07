#lang antenna-turtle

(define (qfhloop scale)
  (reset-model!)
  (model title "QFH" frequency 915)
  (with-scale scale
    (loop for phase = 0 then 270
          for scale = 1.0 then 1.05
          repeat 2 do
          (from-here
            (let [(unit (/ wavelength 3))
                  (last-point (here))
                  (ends '())]
              (with-wire
                (spread left unit feed (center (format "A-~a" phase) 1.0 phase)))
              (loop repeat 2 do
                    (from-here
                      (let [(start (wire-used))]
                        (with-points
                          (loop while (< (- (wire-used) start) (* 1.0 unit scale)) do
                                (point left (half unit))
                                (from-here (move left (half unit))
                                           (set! last-point (here)))
                                (move down inch)
                                (turn left 14)))))
                    (set! ends (cons last-point ends))
                    (turn left 180))
              (goto (car ends))
              (with-wire (goto (cadr ends)))))
          (turn left 90)
          (move down (half centimeter)))))

(qfhloop 0.524)

(export-mmana "../mmana/qfh.maa")

(show-model)

(define pattern (nec2c-radiation-grid #:frequency 915 #:theta-step 1 #:phi-step 1))

(show-radiation-pattern-opengl pattern #:palette 'electric)

(show-return-loss-sweep
 (nec2c-vswr-sweep 500 1400 #:steps 201))
