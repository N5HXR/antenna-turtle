#lang antenna-turtle

(model title "Full Wave Dipole" frequency 14.1)

(with-wire (spread forward wavelength feed center))
(show-model)
(define pattern (nec2c-radiation-grid #:phi-step 1 #:theta-step 1))
(show-radiation-pattern-opengl pattern)
(html-auto-report "scratch/full-wave-dipole.html")
