#lang antenna-turtle

(require "common.rkt")

;; Three-element subset of the measured-dimension family used by
;; examples/yagi-compare.rkt. The unmatched driven element has a low terminal
;; resistance, but NEC2C gives a useful directional reference near 7.25 dBi.
(model title "Verification 12: OpenEMS wire-reference Yagi"
       frequency 146 impedance 50
       max-length (/ wavelength 100)
       wire-diameter (* 6 millimeter))

(define element-layout
  '((reflector 0   990)
    (driven    493 950)
    (director  647 934)))

(with-scale millimeter
  (loop for (role boom-position length) in element-layout do
        (from-here
          (move forward boom-position)
          (with-wire
            (when (eq? role 'driven) (feed center))
            (spread left length)))))

(define estimate
  (simulate engine openems sweep '(130 160) profile wire-reference
            dry-run #t progress #f keep-artifacts #f))
(printf "wire-reference dry run: ~a cells\n"
        (openems-dry-run-cell-count estimate))

;; This is intentionally an opt-in, long validation run. Change to #t only
;; after reviewing the dry-run estimate on the machine doing the solve.
(define run-fdtd? #f)
(when run-fdtd?
  (define nec-sweep (nec2c-vswr-sweep 130 160 #:steps 101))
  (define nec-pattern
    (nec2c-radiation-grid #:frequency 146 #:theta-step 3 #:phi-step 3))
  (define em-result
    (simulate engine openems sweep '(130 160) profile wire-reference
              keep-artifacts #t))
  (define em-pattern
    (openems-radiation-grid em-result #:frequency 146
                            #:theta-step 3 #:phi-step 3))
  (printf "NEC2C Z146: ~a ohms; peak gain ~a dBi\n"
          (impedance-at nec-sweep 146) (maximum-gain nec-pattern))
  (printf "OpenEMS Z146: ~a ohms; peak gain ~a dBi\n"
          (impedance-at em-result 146) (maximum-gain em-pattern)))
