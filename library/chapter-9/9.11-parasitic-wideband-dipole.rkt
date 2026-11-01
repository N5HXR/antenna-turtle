#lang antenna-turtle

(define (build)
  (reset-model!)
  (model title "Parasitic Element Dipole for 80m"
         frequency 3.75
         ground real)
  
  (define vf 0.82)
  (define match-length (* quarter-wave vf))
  (define feed-length (- half-wave match-length foot))
  (define spacing (* 4 inches))
  (define driven-len {802 * inch * 2 * 1.0})
  (define parasitic-len {708 * inch * 2 * 1.0})
  
  (move up half-wave)
  (with-wire
;    (spread forward driven-len port [feedpoint gap inch]))
    (spread forward driven-len feed center))
  (from-here
    (move up spacing)
    (with-wire 
      (spread forward parasitic-len))))

; (coax name quarter-stub
;       type rg6
;       output feedpoint
;       feed none
;       (move down match-length)))
       ;(move down foot)
       ;(lumped-element down gap inch inductance 20e-6)
       ;(move down {match-length - foot - inch})))
; 
; (coax name feedline
;       type rg58
;       output quarter-stub
;       (move down feed-length)
;       (move left feed-length))

;; 802" active and 708" passive
(build)
(show-model)

(define sweep (nec2c-vswr-sweep 3 4.5 #:steps 101))
(show-return-loss-sweep sweep)
(show-smith-chart sweep)

(write-s1p "9.11-parasitic-wideband-dipole.s1p" sweep)
