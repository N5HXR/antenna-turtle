#lang antenna-turtle

(define (loop-radiator altitude)
  ;; (reset-model!)
  ;; (model title "70cm Loop Array"
  ;;        frequency 432
  ;;        ground perfect
  ;;        max-length {wavelength / 100}
  ;;        wire-diameter {3 * millimeters})

  (letrec ((circ wavelength)
           (rad (/ circ pi 2 0.9918)))
    (from-here
      (move up {altitude * millimeters})
      (with-points
        (point right rad)
        (feed center)
        (loop repeat 16 do
              (turn left 22.5)
              (point right rad))))))

;; (loop for altitude from 60 to 90 by 2 do
;;       (loop-radiator altitude)
;;       (letrec ((sweep (nec2c-vswr-sweep 400 474 #:steps 101))
;;                (result (find-s11-minimum sweep))
;;                (freq (first result))
;;                (s11 (second result)))
;;         (display (format "Alt: ~a mm, RL@~a: ~a~n" altitude freq s11))))


;;(loop-radiator 72)
;;(display (format "~a~n" (find-s11-minimum (nec2c-vswr-sweep 420 440 #:steps 101))))

; (define (array2 distance)
;   (reset-model!)
;   (model title "70cm Loop Array"
;          frequency 432
;          ground perfect
;          max-length {wavelength / 100}
;          wire-diameter {3 * millimeters})
;
;   (loop-radiator 72)
;   (move right {distance * wavelength})
;   (loop-radiator 72))
;
; (define (test from to by)
;   (loop for d from from to to by by do
;         (array2 d)
;         (let ((pattern (nec2c-radiation-grid #:theta-step 2 #:phi-step 2)))
;           (display (format "Dist: ~a wl, Gain: ~a~n"
;                            (real->decimal-string d 3)
;                            (maximum-gain pattern))))))
(define (array x y)
  (reset-model!)
  (model title "70cm Loop Array"
         frequency 432
         ground perfect
         nec2-patch-length {wavelength / 10}
         max-length {wavelength / 100}
         wire-diameter {3 * millimeters})

  (define cx (/ (sub1 x) 2))
  (define cy (/ (sub1 y) 2))

  (loop for dx from 0 below x do
        (loop for dy from 0 below y do
              (from-here
                (move right   {(dx - cx) * wavelength}
                      forward {(dy - cy) * wavelength})
                (loop-radiator 72)))))

(array 2 2)
;(move down 0.025)
;(with-body name reflector form surface material pec anchor center
;           (cuboid size '(2.5 2.5 0.05)))

(show-model)

(when #t
  (begin
    (define pattern (nec2c-radiation-grid #:phi-step 2 #:theta-step 2))
    (show-radiation-pattern-opengl pattern #:palette 'sdr))

)

(when #f
  (begin
    (define sweep
      (nec2c-vswr-sweep 425 440 #:steps 31))

    (define pattern
      (nec2c-radiation-grid
       #:theta-step 1
       #:phi-step 1))

    (write-html-report
     sweep
     "scratch/70cm-tiny-array.html"
     #:pattern pattern))
)
