#lang racket

(require antenna-turtle)

;; A deliberately simple acceptance fixture.  At 30 MHz the parallel LC is
;; near resonance, so inserting it in series with the wire should change the
;; feedpoint impedance conspicuously even though the geometry is unchanged.
(define frequency-mhz 30)
(define trap-inductance 1e-6)
(define trap-capacitance
  (/ 1 (* (sqr (* 2 pi (* frequency-mhz 1e6))) trap-inductance)))

(define (build-fixture! loaded?)
  (reset-model!)
  (model title (if loaded?
                   "Dipole with inline parallel LC"
                   "Unloaded dipole reference")
         frequency frequency-mhz
         impedance 50
         max-length 0.05
         wire-diameter 0.002)
  (with-wire
    (move forward 1 feed center)
    (when loaded?
      (lumped-element forward
        name resonator
        inductance trap-inductance
        capacitance trap-capacitance
        resistance 10000
        topology parallel
        gap 0.02))
    (move forward 1)))

(define (fixture-impedance loaded?)
  (build-fixture! loaded?)
  (nec2c-feedpoint-sample-impedance
   (first
    (nec2c-impedance-result-samples
     (nec2c-measure-impedance)))))

(define reference-impedance (fixture-impedance #f))
(define loaded-impedance (fixture-impedance #t))

(printf "unloaded: ~a ohms\n" reference-impedance)
(printf "loaded:   ~a ohms\n" loaded-impedance)
(printf "change:   ~a ohms\n" (- loaded-impedance reference-impedance))

;; Leave the loaded model current for deck inspection or follow-up sweeps in
;; DrRacket/Emacs.  For example: (export-nec2c "/tmp/lumped-wire.nec")
(build-fixture! #t)
