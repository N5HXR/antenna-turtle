#lang antenna-turtle

;; model description
(model title "20m Sloper" frequency 14.1 ground real)

;; model constants
(define dipole-length (* 0.97 half-wave))
(define feed-length (* 1.414 (half dipole-length)))

(turn up 45 left 90)
;; coax outer conductor
(with-wire (move up feed-length))
(move up inch)
;; radiating elements
(with-wire (spread left dipole-length feed center))

;; visual inspection
(show-model)

;; simulation results
(define p (nec2c-radiation-grid))
(define s (nec2c-vswr-sweep
           (half (model-frequency))
           (* 2 (model-frequency)) #:steps 501))

(show-radiation-pattern-opengl p)
(show-return-loss-sweep s)
(when #t (html-auto-report "9.6-sloper.html"))
