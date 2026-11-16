#lang antenna-turtle

;; Published L. B. Cebik/W4RNL dimensions already used by the project. This
;; 29 MHz version retains the 20 mm wire from the original Antenna Turtle
;; example and exercises right-angle bends plus closely spaced open ends.
(model title "Verification 13: OpenEMS wire-reference Moxon"
       frequency 29 impedance 50
       max-length (/ wavelength 120)
       wire-diameter (* 20 millimeter))

(define a (* 147.96 inch))
(define b (* 22.09 inch))
(define c (* 4.28 inch))
(define d (* 27.71 inch))

(define (element short long driven?)
  (with-wire
    (move forward short)
    (when driven? (feed center))
    (move left long)
    (move back short)))

(element b a #t)
(move back c)
(turn left 180)
(element d a #f)

(define estimate
  (simulate engine openems sweep '(25 33) profile wire-reference
            dry-run #t progress #f keep-artifacts #f))
(printf "wire-reference dry run: ~a cells\n"
        (openems-dry-run-cell-count estimate))

;; This is intentionally an opt-in, long validation run. Change to #t only
;; after reviewing the dry-run estimate on the machine doing the solve.
(define run-fdtd? #f)
(when run-fdtd?
  (define nec-sweep (nec2c-vswr-sweep 25 33 #:steps 101))
  (define nec-pattern
    (nec2c-radiation-grid #:frequency 29 #:theta-step 3 #:phi-step 3))
  (define em-result
    (simulate engine openems sweep '(25 33) profile wire-reference
              keep-artifacts #t))
  (define em-pattern
    (openems-radiation-grid em-result #:frequency 29
                            #:theta-step 3 #:phi-step 3))
  (printf "NEC2C Z29: ~a ohms; peak gain ~a dBi\n"
          (impedance-at nec-sweep 29) (maximum-gain nec-pattern))
  (printf "OpenEMS Z29: ~a ohms; peak gain ~a dBi\n"
          (impedance-at em-result 29) (maximum-gain em-pattern)))
