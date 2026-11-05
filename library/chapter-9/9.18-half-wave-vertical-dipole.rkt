#lang antenna-turtle

(define (build choke?)
  (reset-model!)
  (model title "Half Wave Vertical Dipole 20m"
         frequency 14.1
         max-length {wavelength / 100}
         ground real)
  
  (define element {half-wave * 0.97})
  (define segment {wavelength / 100})
  (define center (+ quarter-wave {8 * feet}))
  (define feedlen {(center * 1.414) - 2 * segment})
  
  (move up center)
  (with-wire (spread up element port [feedpoint gap segment]))
  (coax type rg58 output feedpoint
        (turn down 45)
        (move forward segment)
        (when choke? (lumped-element forward inductance 100e-6 gap segment))
        (move forward {element / 2 - segment})
        (when choke? (lumped-element forward inductance 100e-6 gap segment))
        (move forward {element / 2})
        (turn up 45)
        (move forward segment)
        (when choke? (lumped-element forward inductance 100e-6 gap segment))
        (move forward {feedlen / 2 - segment})
        (display (format "Position: ~a~n" (current-position)))
        ))

(define (patternize)
  (letrec ((grid (nec2c-radiation-grid  #:theta-step 1 #:phi-step 1))
           (peak (second (maximum-gain-direction grid)))
           (az (nec2c-azimuth-pattern #:elevation peak #:step 1)))
    (list grid az)))

(build #f)
(define p1 (patternize))

(build #t)
(define p2 (patternize))

(show-radiation-comparison
 (list (radiation-case "No Chokes" (first p1))
       (radiation-case "With Chokes" (first p2)))
 #:palette 'electric)

(show-radiation-cut (second p1) #:floor-db -3 #:normalize? #t)
(show-radiation-cut (second p2) #:floor-db -3 #:normalize? #t)
(show-model)

(define sweep (nec2c-vswr-sweep 13 15))
(show-return-loss-sweep sweep)
