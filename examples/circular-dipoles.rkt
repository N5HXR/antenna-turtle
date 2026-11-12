#lang antenna-turtle

(model
 title "Turnstile"
 frequency 432
 wire-diameter {3 * millimeters}
 max-length {wavelength / 100})

(with-wire (spread forward half-wave feed (center "A" 1.0 0.0)))
(move up centimeter)
(with-wire (spread left half-wave feed (center "B" 1.0 90.0)))

(show-model)

(define pattern (nec2c-radiation-grid))
(show-radiation-pattern-opengl pattern)
