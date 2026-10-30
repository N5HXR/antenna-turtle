#lang antenna-turtle

;; Acceptance fixture for the composite coax model:
;;
;;   * the NEC TL carries the internal differential TEM mode;
;;   * the visible wire descending from the dipole is the radiating exterior
;;     of the shield; and
;;   * impedance is measured at the generated input port one foot above the
;;     perfect ground, not at the antenna terminals.
;;
;; The deliberately shortened hot arm in the third case makes the effects of
;; geometrical imbalance easy to distinguish from the symmetric fixture.

(define frequency-mhz 14.2)
(define feed-height 10.0)
(define input-height foot)
(define feed-gap (* 2 inch))
(define coax-diameter 0.0103)
(define coax-velocity-factor 0.66)
(define conductor-diameter 0.002)
(define nominal-arm-length (- quarter-wave (/ feed-gap 2)))

(define (build-dipole! title coax? hot-arm-scale)
  (reset-model!)
  (model title title
         frequency frequency-mhz
         impedance 50
         ground perfect
         max-length (/ wavelength 40)
         wire-diameter conductor-diameter)
  (move up feed-height)

  ;; Positive/hot arm.
  (from-here
    (move forward (/ feed-gap 2))
    (with-wire
      (when (< hot-arm-scale 1.0) (turn down 30))
      (move forward nominal-arm-length)))

  ;; Negative/cold arm.
  (from-here
    (move back (/ feed-gap 2))
    (with-wire
      (move back nominal-arm-length)))

  (if coax?
      (let ([antenna-port
             (wire-port forward
               name antenna-feed
               gap feed-gap
               diameter conductor-diameter)])
        (coax name feedline
              output antenna-port
              impedance 50
              velocity-factor coax-velocity-factor
              diameter coax-diameter
              color "dark orange"
              input-gap inch
              input-direction forward
              feed input
          ;; The shield exterior terminates in free space, one foot above the
          ;; perfect ground. It is deliberately not connected to ground.
          (move down foot)
          (lumped-element down
            name common-mode-choke
            inductance 33.6e-6
            topology series
            gap inch)
          (move down (- feed-height input-height foot))))
      (from-here
        (move back (/ feed-gap 2))
        (feed center)
        (with-wire (move forward feed-gap)))))

(struct simulation (label impedance pattern) #:transparent)

(define (run-case label coax? hot-arm-scale)
  (build-dipole! label coax? hot-arm-scale)
  (define impedance
    (nec2c-feedpoint-sample-impedance
     (first
      (nec2c-impedance-result-samples
       (nec2c-measure-impedance)))))
  (define pattern
    (nec2c-radiation-grid
     #:frequency frequency-mhz
     #:theta-step 5
     #:phi-step 5))
  (define peak-gain
    (apply max
           (filter real?
                   (map nec2c-pattern-sample-total-gain-db
                        (nec2c-pattern-grid-samples pattern)))))
  (printf "~a: Z = ~a ohms; peak = ~a dBi\n"
          label impedance peak-gain)
  (simulation label impedance pattern))

(define direct
  (run-case "direct feed: symmetric dipole" #f 1.0))
(define symmetric-coax
  (run-case "coax input: symmetric dipole" #t 1.0))
(define unbalanced-coax
  (run-case "coax input: hot arm tilted" #t 0.90))

;; Leave the unbalanced coax model current for show-model, export-nec2c, or
;; subsequent current/radiation inspection at the REPL.
(build-dipole! (simulation-label unbalanced-coax) #t 0.90)
(unless (getenv "ANTENNA_TURTLE_NO_GUI")
  (show-model #:legend? #t)
  (show-radiation-comparison
   (list
    (radiation-case (simulation-label direct) (simulation-pattern direct))
    (radiation-case (simulation-label symmetric-coax)
                    (simulation-pattern symmetric-coax))
    (radiation-case (simulation-label unbalanced-coax)
                    (simulation-pattern unbalanced-coax)))
   ;#:difference? #t
   ;#:difference-range-db 'auto
   #:palette 'electric
   #:scale 'arrl))
