#lang antenna-turtle

(define view 'ref)

(model title "Helix Antenna"
       frequency 432
       wire-diameter {3 * millimeters}
       ground none
       max-length {wavelength / 50})

(define (helix pitch radius)
  (clear-wires)
  (define upstep {(pitch * wavelength) / 12})

  (circular-wire-mesh {radius * 8} 16 8)

  (with-points
    (point right radius)
    (move up inch)
    (feed start)
    (point right radius)
    (turn up 90)
    (loop repeat 48 do
          (turn roll-right 30)
          (move forward upstep)
          (point right radius))))

;; Modes for the experiment; 'ref is the "best case so far"
;; after optimizing some of the parameters.

(cond
  ;; best version based on optimization runs
  [(eq? view 'ref)
   (helix 0.18 {0.95 * wavelength / pi / 2})
   (show-model)
   (define pattern (nec2c-radiation-grid))
   (show-radiation-pattern-opengl pattern)]

  ;; optimizing pitch
  [(eq? view 'opt-pitch)
   (loop for pitch from 0.1 to 0.3 by 0.01 do
         (helix pitch {wavelength / pi / 2})
         (define pattern (nec2c-radiation-grid))
         (display (format "Pitch: ~a lambda, Gain: ~a dBi~n"
                          (real->decimal-string pitch 3)
                          (real->decimal-string (maximum-gain pattern) 3))))]

  ;; optimizing radius
  [(eq? view 'opt-radius)
   (loop for circ from 0.5 to 1.5 by 0.05 do
         (helix 0.18 {circ * wavelength / pi / 2})
         (define pattern (nec2c-radiation-grid))
         (display (format "Circ: ~a lambda, Gain: ~a dBi~n"
                          (real->decimal-string circ 3)
                          (real->decimal-string (maximum-gain pattern) 3))))])
