#lang antenna-turtle

(model title "Three-element Yagi geometry"
       frequency 150.0
       max-length (/ wavelength 100)
       wire-diameter (* 6 millimeter))

;; Keep each element's role, boom position, and total length together. LOOP
;; destructuring makes those columns explicit at the point of use.
(define element-layout
  (list (list 'reflector  0                    (* 0.52 wavelength))
        (list 'driven    (* 1/5 wavelength)   (* 0.48 wavelength))
        (list 'director  (* 2/5 wavelength)   (* 0.45 wavelength))))

(define (element role boom-position length)
  (from-here
    (move forward boom-position)
    (when (eq? role 'driven) (feed 'center))
    (with-wire
      ;; Center every transverse element on its boom attachment point.
      (spread right length))))

(loop for (role boom-position length) in element-layout
      do (element role boom-position length))
