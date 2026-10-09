#lang antenna-turtle

(require (prefix-in m: manifold))

;; A deliberately simple two-port structure for exercising the complete
;; OpenEMS S-matrix workflow. It is a transmission-line example, not a
;; precision 50-ohm design; tune trace width and substrate properties for a
;; particular fabrication stackup.
(model title "OpenEMS two-port microstrip through line"
       frequency 2450
       impedance 50)

(define board-length 0.080)
(define board-width 0.040)
(define substrate-height 0.0016)
(define trace-width 0.004)
(define port-x 0.030)
(define port-width trace-width)
(define port-depth 0.002)

(define substrate-material
  (dielectric #:name 'substrate #:relative-permittivity 3.0))
(define substrate
  (m:cube board-length board-width substrate-height #:center? #t))

(body substrate
      geometry substrate
      material substrate-material
      priority 10)

(sheet ground
       points `((,(- (/ board-length 2)) ,(- (/ board-width 2)))
                (,(+ (/ board-length 2)) ,(- (/ board-width 2)))
                (,(+ (/ board-length 2)) ,(+ (/ board-width 2)))
                (,(- (/ board-length 2)) ,(+ (/ board-width 2))))
       material pec
       priority 20)

(move up substrate-height)
(sheet trace
       points `((,(- (/ board-length 2)) ,(- (/ trace-width 2)))
                (,(+ (/ board-length 2)) ,(- (/ trace-width 2)))
                (,(+ (/ board-length 2)) ,(+ (/ trace-width 2)))
                (,(- (/ board-length 2)) ,(+ (/ trace-width 2))))
       material pec
       priority 20)

;; Put the turtle halfway between ground and trace. In a multiport model the
;; backend does not rotate anything: both complete port frames must already be
;; aligned with global X/Y/Z. These two local +Z ports satisfy that rule.
(move down (/ substrate-height 2))
(from-here
  (move back port-x)
  (port up name 'input impedance 50
        gap substrate-height width port-width depth port-depth))
(from-here
  (move forward port-x)
  (port up name 'output impedance 50
        gap substrate-height width port-width depth port-depth))

(m:solid-close! substrate)

(show-solid-model)

(define result
  (openems-sweep 1800 3000
                 #:steps 121
                 #:end-criteria 1e-4
                 #:keep-artifacts? #t))

;; Diagonal terms remain available through the familiar one-port views.
(show-return-loss-sweep result)
(show-impedance-sweep result)
(show-smith-chart result)

;; The complete two-port matrix gets dedicated magnitude and phase views.
(show-s-parameter-magnitude result)
(show-s-parameter-phase result)

;; Each excitation recorded its own NF2FF data. Select the driven port when
;; asking for a radiation pattern.
;; (define input-radiation
;;   (openems-radiation-grid result #:excitation 'input))
;; (show-radiation-pattern-opengl input-radiation #:palette 'inferno)
