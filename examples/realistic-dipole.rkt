#lang antenna-turtle

(model
 title "Three-Mast 20m Dipole"
 frequency 14.1
 max-length {wavelength / 100})

(define mast-spacing {4.8 * meter})
(define sag meter)
(define segments-per-span 24)

;; One span, centered between two adjacent masts.
(define hanging-span (catenary mast-spacing sag))

;; Fold both spans onto the same catenary. Masts occur at
;; x = -mast-spacing, 0, and +mast-spacing.
(define (three-mast-profile x y)
  (hanging-span
   (- (abs x) (half mast-spacing))
   y))

;; empirically determined tuning factor for pretty VSWR
(with-scale 0.96

  ;; put a feedpoint at the center
  (with-surface three-mast-profile
    (with-wire (spread forward foot feed 'center)))

  ;; drape wire in both directions for the dipole
  (reflect forward
    (with-surface three-mast-profile
      (move forward (half foot))
      (with-wire
	(move forward mast-spacing steps segments-per-span)))))

(export-mmana "mmana/realistic-dipole.maa")
