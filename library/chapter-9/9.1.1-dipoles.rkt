#lang antenna-turtle

(define table
  ;; frequency 468/f 485/f 490/f
  '((1.85 253.0 262.2 264.9)
    (3.6 130.0 134.7 136.1)
    (3.9 120.0 124.4 125.6)
    (5.3 88.3 91.5 92.5)
    (7.1 65.9 68.3 69.0)
    (10.1 46.3 48.0 48.5)
    (14.15 33.1 34.3 34.6)
    (18.1 25.9 26.8 27.1)
    (21.2 22.1 22.9 23.1)
    (24.9 18.8 19.5  19.7)
    (28.2 16.6 17.2 17.4)
    (29 16.1 16.7 16.9)
    (50.1 9.3 9.7 9.8)))

(define (build freq len)
  (reset-model!)
  (model title (format "9.1.1 Dipole: ~a MHz" freq)
         frequency freq)
  (with-scale feet
    (with-wire
      (spread left len feed center))))

(define (measure-row row)
  (let ((freq (first row))
        (lens (rest row)))
    (loop for len in lens do
          (build freq len)
          (letrec ((s (nec2c-vswr-sweep (* freq 0.5) (* freq 2.0) #:steps 301))
                   (v (vswr-at s freq)))
            (display (format "~a MHz, ~a feet, VSWR: ~a~n" freq len v))))))

(map measure-row table)


