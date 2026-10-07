#lang antenna-turtle

(model
 title "Meshtastic Franklin Array"
 frequency 915)

;; some antenna design parameters
(define element-count 3)

;; empirically determined tuning parameters
(define tune-stub 1.03)
(define tune-scale 0.98)

;; franklin arrays use tuning stubs to align collinear elements
(define stub-length (* tune-stub quarter-wave))
(define stub-width centimeter)

;; One U-shaped phasing stub between collinear half-wave sections.
(define (phasing-stub)
  (move left stub-length)
  (move up stub-width)
  (move right stub-length))

;; Construct one side. `reflect` retains this feed and suppresses it on the
;; generated copy.
(define (half-array)
  (with-wire
    (move up quarter-wave feed 'start)
    (loop repeat element-count do
      (phasing-stub)
      (move up half-wave))))

;; Reflect across the local XY plane at the feedpoint. The body runs once;
;; only its generated wire geometry is copied to the opposite side.
(with-scale tune-scale
  (reflect up
    (half-array)))

;; test in MMANA-GAL
(export-mmana "mmana/franklin.maa")
