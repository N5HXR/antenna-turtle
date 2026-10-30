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

(define (build-dipole! title)
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
      (turn down 30)
      (move forward nominal-arm-length)))

  ;; Negative/cold arm.
  (from-here
    (move back (/ feed-gap 2))
    (with-wire
      (move back nominal-arm-length)))

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
          ;(lumped-element down
          ;  name common-mode-choke
          ;  inductance 33.6e-6
          ;  topology series
          ;  gap inch)
          (move down (- feed-height input-height foot)))))

(struct simulation (label impedance pattern) #:transparent)

(build-dipole! "Normal")

(define sweep
  (nec2c-vswr-sweep 13.5 14.5 #:steps 101))

(define pattern
  (nec2c-radiation-grid
   #:frequency frequency-mhz
   #:theta-step 3
   #:phi-step 3))

(write-html-report
 sweep
 "scratch/coax-tilted-report-no-choke.html"
 #:pattern pattern
 #:near-fields
 (list
  ;; Y-normal plane: the XZ plane containing the dipole arm and coax.
  (near-field-section
   #:plane 'xz
   #:position 0
   #:x-range (list -12 12)
   #:z-range (list 0 14)
   #:samples '(241 181))

  ;; Horizontal section near the antenna feed.
  (near-field-section
   #:plane 'z
   #:position feed-height
   #:x-range (list -12 12)
   #:y-range (list -12 12)
   #:samples '(181 181))))
