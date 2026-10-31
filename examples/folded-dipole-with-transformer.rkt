#lang antenna-turtle

(model
 title "Folded Dipole w/ Transformer"
 frequency 14.1
 ground real)

(define leg (* 0.93 quarter-wave))

(move up 10)

(from-here
  (reflect forward
    (move forward (half centimeter))
    (with-wire
      (move forward leg)
      (move up (* 2/3 meter))
      (move back (+ leg (half centimeter))))))

(define feedpoint
  (from-here
    (wire-port forward
               name antenna-feed
               gap centimeter
               diameter (current-wire-diameter))))

;; The folded-dipole port follows the horizontal feed gap. The transformer
;; primary points from shield to inner conductor along the vertical coax axis.
;; `from-here` keeps both placements local to the feed.
(define transformer-primary
  (from-here
    (move down centimeter)
    (wire-port up
               name transformer-primary
               gap centimeter
               diameter (current-wire-diameter))))

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

(ideal-transformer
 name transformer-4:1
 input transformer-primary
 output feedpoint
 turns-ratio 2)

;(show-model)

; (export-nec2c "folded-dipole-with-transformer.nec")
(define s (nec2c-vswr-sweep 12 16 #:steps 201))
;(show-return-loss-sweep s)
;(show-smith-chart s)

(html-auto-report "scratch/folded-dipole-with-transformer.html")
