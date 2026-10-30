#lang antenna-turtle

;; Wideband N5HXR Vertical Antenna
;;
;; This fixture deliberately uses separate band scenarios.  The present NEC2C
;; backend cannot yet connect both coaxial modes through one branching diplexer:
;;
;;   * 'vhf and 'uhf excite the differential TEM mode inside the 10 m mast
;;     coax.  Its visible shield-exterior wire remains free to carry and radiate
;;     common-mode current.
;;   * 'hf excites that shield exterior as a vertical.  A second LMR-240 line
;;     drives it against a short ground bond into NEC real ground.
;;
;; The unselected diplexer branch is consequently an ideal open circuit.  The
;; fiberglass mast is omitted: NEC2C-N5HXR currently cannot combine dielectric
;; volumes with the TL/LD cards used by coax and lumped loads.  LMR-240 is also
;; lossless here; its 0.83 velocity factor and physical diameter are modeled,
;; but manufacturer attenuation must be applied separately.

(provide
 n5hxr-scenario-names
 build-n5hxr!
 run-n5hxr-sweep
 run-n5hxr-pattern)

;; Shared physical dimensions.
(define mast-height 10.0)
(define lmr240-diameter 0.006096)
(define lmr240-velocity-factor 0.83)
(define lmr240-impedance 50)
(define radiator-diameter 0.003)

;; The approximately 0.50 m whip is near a quarter wave on 2 m and three
;; quarters of a wavelength on 70 cm.  Four 0.52 m radials form its return at
;; the mast head and become a conductive top hat in the HF scenario.
(define top-whip-length 0.46)
(define top-radial-length 0.48)
(define top-feed-gap 0.02)

;; Differential mast-coax input plane for the VHF/UHF scenarios.
(define main-coax-input-height 0.30)
(define coax-input-gap inch)

;; HF injection fixture.  The output of a second coax is 5 cm above ground:
;; its center reaches the mast-coax exterior through the port's positive
;; terminal, while its shield reaches real ground through the short bond on
;; the negative terminal.  The explicit 3 m shield route is intentionally
;; retained because it can carry common-mode current of its own.
(define hf-ground-bond-height 0.05)
(define hf-injection-gap 0.05)
(define hf-feedline-length 3.0)

(struct n5hxr-scenario
  (name label mode mesh-frequency sweep-start sweep-stop sweep-steps
        pattern-frequency)
  #:transparent)

(define hf-scenario
  (n5hxr-scenario
   'hf "HF: mast-coax exterior vertical" 'hf
   30.0 1.8 30.0 283 7.1))

(define vhf-scenario
  (n5hxr-scenario
   'vhf "VHF: differential mast-coax feed" 'differential
   170.0 120.0 170.0 201 146.0))

(define uhf-scenario
  (n5hxr-scenario
   'uhf "UHF: differential mast-coax feed" 'differential
   470.0 400.0 470.0 281 446.0))

(define n5hxr-scenarios
  (list hf-scenario vhf-scenario uhf-scenario))

(define n5hxr-scenario-names
  (map n5hxr-scenario-name n5hxr-scenarios))

(define (resolve-scenario value)
  (cond
    [(n5hxr-scenario? value) value]
    [(symbol? value)
     (or (for/first ([candidate (in-list n5hxr-scenarios)]
                     #:when (eq? value (n5hxr-scenario-name candidate)))
           candidate)
         (raise-arguments-error
          'build-n5hxr! "unknown scenario"
          "scenario" value
          "expected one of" n5hxr-scenario-names))]
    [else
     (raise-argument-error
      'build-n5hxr! "(or/c 'hf 'vhf 'uhf n5hxr-scenario?)" value)]))

;; Add the four VHF/UHF radials at the current mast-head position.  They are
;; ordinary connected conductors, not NEC's infinite earth ground.
(define (add-top-radials!)
  (from-here
    (loop repeat 4 do
          (from-here
            (turn down 30)
            (with-wire
              (move forward top-radial-length)))
          (turn left 90))))

(define (add-fed-top-assembly!)
  (add-top-radials!)
  (from-here
    (move up top-feed-gap)
    (with-wire (move up top-whip-length)))
  ;; Negative terminal: radial hub and shield exterior.
  ;; Positive terminal: exposed center-conductor whip.
  (wire-port up
    name top-antenna-port
    gap top-feed-gap
    diameter radiator-diameter
    anchor start))

(define (add-hf-top-assembly!)
  (add-top-radials!)
  ;; The diplexer's VHF/UHF branch is approximated as open at HF, leaving the
  ;; exposed whip as a nearby floating parasitic.  A later circuit model should
  ;; replace this with the branch's actual stop-band impedance and the main
  ;; coax's open-stub transformation.
  (from-here
    (move up top-feed-gap)
    (with-wire (move up top-whip-length))))

(define (build-differential-scenario! scenario)
  (move up mast-height)
  (define antenna-port (add-fed-top-assembly!))
  (coax name mast-coax
        output antenna-port
        impedance lmr240-impedance
        velocity-factor lmr240-velocity-factor
        diameter lmr240-diameter
        color "dark orange"
        input-gap coax-input-gap
        input-direction forward
        feed input
    (move down foot)
    ;(lumped-element down
    ;  name vhf-common-mode-choke
    ;  inductance 1e-6
    ;  topology series
    ;  gap 0.03)
    (move down (- mast-height main-coax-input-height foot))))

(define (build-hf-scenario! scenario)
  ;; Place the negative terminal just above ground.  Its short downward lead
  ;; terminates at z=0, which NEC treats as connection to the selected ground.
  (move up hf-ground-bond-height)
  (define injection-port
    (wire-port up
      name hf-injection-port
      gap hf-injection-gap
      diameter lmr240-diameter
      anchor start))

  (from-here
    (with-wire (move down hf-ground-bond-height)))

  ;; Positive side of the HF injection port becomes the exterior of the mast
  ;; coax and rises to the 10 m mast head.
  (from-here
    (move up hf-injection-gap)
    (with-wire
      (move up (- mast-height
                  hf-ground-bond-height
                  hf-injection-gap)))
    (add-hf-top-assembly!))

  ;; The second coax is the HF feedline.  Its center drives the positive port
  ;; terminal; its shield and exterior begin on the grounded negative side.
  (coax name hf-feedline
        output injection-port
        impedance lmr240-impedance
        velocity-factor lmr240-velocity-factor
        diameter lmr240-diameter
        color "dark green"
        input-gap coax-input-gap
        input-direction up
        feed input
    (move forward hf-feedline-length)))

(define (build-n5hxr! value)
  (define scenario (resolve-scenario value))
  (reset-model!)
  (model title (format "Wideband N5HXR Vertical Antenna — ~a"
                       (n5hxr-scenario-label scenario))
         ;; Segment for the top of this scenario's sweep, not merely its
         ;; representative pattern frequency.
         frequency (n5hxr-scenario-mesh-frequency scenario)
         impedance 50
         ground real
         wire-diameter radiator-diameter)
  (case (n5hxr-scenario-mode scenario)
    [(hf) (build-hf-scenario! scenario)]
    [(differential) (build-differential-scenario! scenario)])
  scenario)

(define (run-n5hxr-sweep value)
  (define scenario (build-n5hxr! value))
  (nec2c-vswr-sweep
   (n5hxr-scenario-sweep-start scenario)
   (n5hxr-scenario-sweep-stop scenario)
   #:steps (n5hxr-scenario-sweep-steps scenario)))

(define (run-n5hxr-pattern value
                            #:theta-step [theta-step 5]
                            #:phi-step [phi-step 5])
  (define scenario (build-n5hxr! value))
  (nec2c-radiation-grid
   #:frequency (n5hxr-scenario-pattern-frequency scenario)
   #:theta-step theta-step
   #:phi-step phi-step))

;; Select the model displayed when this file is run directly:
;;
;;   N5HXR_SCENARIO=hf  racket examples/n5hxr.rkt
;;   N5HXR_SCENARIO=vhf racket examples/n5hxr.rkt
;;   N5HXR_SCENARIO=uhf racket examples/n5hxr.rkt
(define selected-scenario-name
  (string->symbol (or (getenv "N5HXR_SCENARIO") "vhf")))

(build-n5hxr! selected-scenario-name)

(unless (getenv "ANTENNA_TURTLE_NO_GUI")
  (show-model #:legend? #t))

(define sweep (nec2c-vswr-sweep 100 200 #:steps 201))
(define pattern (nec2c-radiation-grid #:frequency 146 #:theta-step 1 #:phi-step 1))
(show-return-loss-sweep sweep)
(show-smith-chart sweep)
(show-radiation-pattern-opengl pattern #:palette 'electric)

(write-html-report
 sweep
 "scratch/n5hxr-vertical-no-choke.html"
 #:pattern pattern)
