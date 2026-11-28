#lang antenna-turtle

; (model title "Long OCFD" frequency 14.1)
;
; (with-wire
;   (move forward half-wave feed end)
;   (move forward {half-wave * 3}))

(model title "Illustrative Moxon rectangle geometry"
       frequency 29
       max-length (/ wavelength 120)
       wire-diameter (* 2 millimeter))

;; Parameters for the Moxon from:
;; https://antenna2.github.io/cebik/content/moxon/moxpage.html

(define *a* (* 147.96 inch))
(define *b* (* 22.09 inch))
(define *c* (* 4.28 inch))
(define *d* (* 27.71 inch))

;; Document info

(model-title "Moxon for 29MHz")
(maximum-segment-length (/ (* 10 meter) 20))
(mmana-frequency 29.0)
(wire-diameter (* 20 millimeter))

;; Moxons are built from a "U" shaped element

(define (element short long feed?)
  (with-wire
   (move forward short)
   (when feed? (feed center))
   (move left long)
   (move back short)))

;; Driven element
(element *b* *a* #t)

;; Small gap
(move back *c*)
(turn left 180)

;; Reflector element
(element *d* *a* #f)

(define fields
  (nec2c-near-field-planes
   #:planes
   (list
    (near-field-section
     #:plane 'xy
     #:samples '(181 121)))))

(show-near-field-poynting-particles fields #:particles 20000)
(html-auto-report "scratch/moxon.html")
