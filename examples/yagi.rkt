#lang antenna-turtle

(model title "Three-element Yagi geometry"
       frequency 150.0
       max-length (/ wavelength 100)
       wire-diameter (* 6 millimeter))

;; Keep each element's role, boom position, and total length together. LOOP
;; destructuring makes those columns explicit at the point of use.
(define element-layout
  (list (list 'reflector  0                   (* 0.52 wavelength))
        (list 'driven    (* 1/5 wavelength)   (* 0.48 wavelength))
        (list 'director  (* 2/5 wavelength)   (* 0.45 wavelength))))

(define (element role boom-position length)
  (from-here
    (move forward boom-position)
    (when (eq? role 'driven) (feed center))
    (with-wire
      ;; Center every transverse element on its boom attachment point.
      (spread right length))))

(loop for (role boom-position length) in element-layout
      do (element role boom-position length))

;; (export-mmana "mmana/yagi.maa")

(define impedance
  (nec2c-measure-impedance))

(define sweep
  (nec2c-vswr-sweep 120 180 #:steps 51))

(define azimuth
  (nec2c-azimuth-pattern #:elevation 0 #:step 2))

(define sphere
  ;; The 5-degree defaults are already finer than this interactive plot needs.
  (nec2c-radiation-grid))

(show-vswr-sweep sweep)
(show-radiation-cut azimuth)
;; Fast, conservative Plot3D baseline.
(show-radiation-pattern-3d sphere)
;; GPU-accelerated, smoothly colorized view of the same result data.
(show-radiation-pattern-opengl sphere)
