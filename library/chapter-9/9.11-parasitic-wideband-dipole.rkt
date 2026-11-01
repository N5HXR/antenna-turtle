#lang antenna-turtle

(define (build)
  (reset-model!)
  (model title "Parasitic Element Dipole for 80m"
         frequency 3.75
         max-length {wavelength / 200}
         ground real)
  
  (define vf 0.82)
  (define match-length {68 * feet})
  (define feed-length (- half-wave match-length foot))
  (define spacing (* 10 inches))
  (define driven-len {802 * inch * 2 * 1.01})
  (define parasitic-len {708 * inch * 2 * 1.01})
  (define segment {wavelength / 200})
  
  (move up half-wave)
  (with-scale 1.02
    (with-wire
      (spread forward driven-len port [feedpoint gap segment]))
    (from-here
      (move up spacing)
      (with-wire 
        (spread forward parasitic-len))))

 (coax name quarter-stub
       type rg6
       output feedpoint
       feed none
       (move down segment)
       (lumped-element down gap segment inductance 300e-6)
       (move down {match-length - segment}))
  
  (coax name feedline
        type rg58
        output quarter-stub
        (move down feed-length)
        (move left feed-length)))

(build)
(show-model)

(define sweep (nec2c-vswr-sweep 3 4.5 #:steps 101))
(show-return-loss-sweep sweep)

;(show-smith-chart sweep)
;(write-s1p "9.11-parasitic-wideband-dipole.s1p" sweep)
