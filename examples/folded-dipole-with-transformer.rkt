#lang antenna-turtle

(model
 title "Folded Dipole w/ Transformer"
 frequency 14.1
 ground real)

(move up 10)

(from-here
  (reflect forward
    (move forward (half centimeter))
    (with-wire
      (move forward quarter-wave)
      (move up (half foot))
      (move back (+ quarter-wave (half centimeter))))))

(define feedpoint
  (from-here
    (wire-port forward
               name antenna-feed
               gap centimeter
               diameter centimeter)))

;; The folded-dipole port follows the horizontal feed gap. The transformer
;; primary points from shield to inner conductor along the vertical coax axis.
;; `from-here` keeps both placements local to the feed.
(define transformer-primary
  (from-here
    (move down centimeter)
    (wire-port up
               name transformer-primary
               gap centimeter
               diameter centimeter)))

;; This draws the outer conductor and creates a 50-ohm NEC TL from its driven
;; input port to transformer-primary. The NT card connects that same primary
;; port to the folded-dipole feedpoint.
(coax name feedline
      output transformer-primary
      impedance 50
      velocity-factor 0.66
      diameter centimeter
      color "purple"
      input-gap centimeter
      input-direction up
      feed input
      (move down (- 10 foot)))

(two-port-y
 name transformer-4:1
 input transformer-primary
 output feedpoint
 y11 999.968228-0.002500i
 y12 -499.984114+0.000750i
 y22 249.992057-0.000625i)

(show-model)

; (export-nec2c "folded-dipole-with-transformer.nec")
(define s (nec2c-vswr-sweep 12 16 #:steps 201))
(show-return-loss-sweep s)
(show-smith-chart s)
