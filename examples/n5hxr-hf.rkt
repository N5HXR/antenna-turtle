#lang antenna-turtle

(require racket/set)

(define (build height inductance)
  (reset-model!)
  (model title "N5HXR Vertical in HF Mode"
         ground perfect
         frequency 7.1)
  (with-wire
    (move up inch feed start)
    (lumped-element up
      gap inch
      name load-coil
      topology series
      inductance inductance)
    (move up height))
  (from-here
    (loop repeat 4 do
          (from-here (turn down 30) (with-wire (move forward 0.48)))
          (turn left 90)))
  (from-here
    (with-wire
      (move up 0.46))))

(define bands '(3.6 3.9 7.1 10.125 14.1 18.1 21.1 24.9 28.1))
;
; (define (find-length)
;   (loop for vlen from 3 to 12 do
;         (loop for rlen from 1 to 9 by 2 do
;               (build vlen inductance)
;               (let ((sweep (nec2c-vswr-sweep 3 30 #:steps 201)))
;                 (let ((bc (count (lambda (x) (<= x 10)) (get-matches sweep bands))))
;                   (display (format "~a meters, ~a meters -> ~a bands~n"
;                                    (~a "" vlen #:min-width 4 #:align 'right)
;                                    (~a "" rlen #:min-width 4 #:align 'right)
;                                    bc)))))))

; (when #f
;   (begin
;     (find-length)
;     )
;   )

(when #f
  (begin
    (let ((w (mutable-set)))
      (loop for i from 0.25 to 20.0 by 0.25
            do
            (build 9 (* i 1e-6))
            (let ((s (nec2c-vswr-sweep 3 30 #:steps 201)))
              (loop for b in bands do
                    (let ((v (vswr-at s b #:interpolate? #t)))
                      (when (< v 10.0)
                        (when (not (set-member? w b))
                            (display (format "~a uH ~a MHz ~a~n"
                                             (~a "" i #:min-width 5 #:align 'right)
                                             (~a "" b #:min-width 5 #:align 'right)
                                             v)))
                        (set-add! w b))))))
      (display (format "~a~n" w))))

  )

(when #f

  (begin
    (build 8 2e-6)
    (show-model)
    (let ((s (nec2c-vswr-sweep 3 30 #:steps 201)))
      (show-vswr-sweep s)
      )
    )

  )
