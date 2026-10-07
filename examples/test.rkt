#lang antenna-turtle

(model
 title "HF Dipole"
 frequency 14.1
 ground real
 height wavelength
)

(define (build scale)
  (clear-wires)
  (with-scale scale
    (with-wire
      (spread left half-wave feed center))))

(define (measure)
  (nec2c-radiation-grid #:theta-step 1 #:phi-step 1))

(build 1.0)
(define m (measure))
(define m2 (measure))
(define m3 (measure))
(define m4 (measure))

(define comparison
  (list
   (radiation-case "half wave up" m)
   (radiation-case "quarter wave up" m2)
   (radiation-case "eighth wave up" m3)
   (radiation-case "full wave up" m4)))

(show-radiation-pattern-opengl m #:palette 'mmana)
(show-radiation-comparison comparison #:aspect-ratio 16/9 #:palette 'mmana #:scale 'arrl)
