#lang antenna-turtle

(require (prefix-in m: manifold))

;; Three-resonator distributed bandpass example using the dimensions in the
;; Marki Microwave calculator result supplied with the model. This is intended
;; to exercise Antenna Turtle's two-port OpenEMS path; connector launches,
;; enclosure effects, fabrication tolerances, and tuning are deliberately not
;; represented.
(model title "OpenEMS 2.2--2.6 GHz third-order interdigital bandpass"
       frequency 2400
       impedance 50)

(define epsilon-r 4.2)
(define substrate-height 254e-6)
(define copper-thickness 10e-6)
(define feed-width 491.4e-6)       ; W0
(define resonator-width 491.4e-6)  ; W
(define resonator-length 17.51e-3) ; L
(define tap-height 4.430e-3)       ; t
(define end-offset 852.1e-6)       ; e
(define resonator-gap 247.6e-6)    ; S1 = S2

(define pitch (+ resonator-width resonator-gap))
(define left-center (- pitch))
(define middle-center 0)
(define right-center pitch)
(define feed-length 5e-3)
(define board-margin 2e-3)
(define filter-width (+ (* 3 resonator-width) (* 2 resonator-gap)))
(define board-width (+ filter-width (* 2 (+ feed-length board-margin))))
(define board-length (+ resonator-length end-offset (* 2 board-margin)))
(define board-y-min (- board-margin))
(define board-y-max (- board-length board-margin))

(define substrate-material
  (dielectric #:name 'substrate #:relative-permittivity epsilon-r))
(define copper
  (conducting-sheet-material #:name 'copper
                             #:conductivity 5.8e7
                             #:thickness copper-thickness))

(define raw-substrate
  (m:cube board-width board-length substrate-height #:center? #t))
(define substrate
  (m:translate raw-substrate `(0 ,(/ (+ board-y-min board-y-max) 2)
                                      ,(/ substrate-height 2))))
(m:solid-close! raw-substrate)

(body name substrate
      geometry substrate
      material substrate-material
      priority 10
      coordinates world)

(define (rectangle x-low x-high y-low y-high)
  `((,x-low ,y-low)
    (,x-high ,y-low)
    (,x-high ,y-high)
    (,x-low ,y-high)))

;; Continuous ground plane at z=0.
(sheet name ground
       points (rectangle (- (/ board-width 2)) (/ board-width 2)
                         board-y-min board-y-max)
       material copper
       priority 20)

;; Top copper. Outer resonators are grounded at their lower ends; the middle
;; resonator is offset upward and grounded at its upper end.
(move up substrate-height)
(define (resonator-points center y-low)
  (rectangle (- center (/ resonator-width 2))
             (+ center (/ resonator-width 2))
             y-low (+ y-low resonator-length)))

(sheet name resonator-1
       points (resonator-points left-center 0)
       material copper priority 20)
(sheet name resonator-2
       points (resonator-points middle-center end-offset)
       material copper priority 20)
(sheet name resonator-3
       points (resonator-points right-center 0)
       material copper priority 20)

;; Lateral input and output taps at height t.
(define outer-edge (+ pitch (/ resonator-width 2)))
(define input-x (- (- outer-edge) feed-length))
(define output-x (+ outer-edge feed-length))
(sheet name input-feed
       points (rectangle input-x left-center
                         (- tap-height (/ feed-width 2))
                         (+ tap-height (/ feed-width 2)))
       material copper priority 20)
(sheet name output-feed
       points (rectangle right-center output-x
                         (- tap-height (/ feed-width 2))
                         (+ tap-height (/ feed-width 2)))
       material copper priority 20)

;; Explicit PEC shorting walls connect the alternating resonator ends to the
;; ground plane. Each wall occupies one strip-width square at the grounded end.
(define (shorting-wall name center-x center-y)
  (define primitive
    (m:cube resonator-width resonator-width substrate-height #:center? #t))
  (define placed
    (m:translate primitive `(,center-x ,center-y ,(/ substrate-height 2))))
  (m:solid-close! primitive)
  ;; This PEC wall deliberately meets the finite-conductivity copper sheets.
  ;; Its higher priority gives CSXCAD deterministic ownership at the junction.
  (add-body name pec placed #:priority 21 #:coordinates 'world)
  (m:solid-close! placed))

(shorting-wall 'short-1 left-center (/ resonator-width 2))
(shorting-wall 'short-2 middle-center
               (- (+ end-offset resonator-length)
                  (/ resonator-width 2)))
(shorting-wall 'short-3 right-center (/ resonator-width 2))

;; Return the turtle to the port mid-plane. Multiport export intentionally
;; performs no automatic rotation, so both complete frames remain aligned to
;; global X/Y/Z as required by the Yee grid.
(move down (/ substrate-height 2))
(from-here
  (move back (- (- input-x) (/ feed-length 4))
        left tap-height)
  (port up name 'input impedance 50
        gap substrate-height width feed-width depth feed-width))
(from-here
  (move forward (- output-x (/ feed-length 4))
        left tap-height)
  (port up name 'output impedance 50
        gap substrate-height width feed-width depth feed-width))

(m:solid-close! substrate)

(show-solid-model)

(define result
  (openems-sweep 1800 3000
                 #:steps 121
                 #:end-criteria 1e-4
                 #:keep-artifacts? #t))

(show-s-parameter-magnitude result)
(show-s-parameter-phase result)
(show-return-loss-sweep result)
(show-smith-chart result)
