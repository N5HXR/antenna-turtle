#lang antenna-turtle

;; NEC2C-N5HXR dielectric comparison derived from projects/quarter.rkt.  The
;; panel is declared once; #:dielectrics? selects a reference or loaded solve
;; without rebuilding or moving the antenna geometry.
(model title "Quarter-wave antenna with nearby dielectric panel"
       frequency 1296
       ;; Dielectric revision 1 does not support conductor/ground contact.
       ;; Lift the source model just beyond its default 0.5 mm wire radius.
       height (* 2 millimeter))

(define short-unit {0.707 * quarter-wave / 4})
(define long-unit (* short-unit (sqrt 2)))
(define mast-len {wavelength * 0.73})

(define (slope x y)
  (* -1
     (/ (+ x y) (sqrt 2))
     (tan (/ pi 4))))

(move up mast-len)

;; The turtle is now at the feed location and faces horizontally.  Declare
;; the obstruction outside the antenna's construction scale so its dimensions
;; remain the stated physical dimensions.  Its near face is 0.20 free-space
;; wavelength away along X; lifting its lower edge 25 mm above the feed clears
;; the source model's four sloping wire grids.
(define obstruction-material
  (dielectric name validation-panel er 6.0))
(define fft-cell-size 0.0075)
(define nominal-panel-bottom
  (+ mast-len 0.075 -0.0525 (model-height)))
(define fft-panel-bottom
  (* fft-cell-size
     (+ 1/2 (ceiling (- (/ nominal-panel-bottom fft-cell-size) 1/2)))))
(define panel-lift
  (- fft-panel-bottom mast-len (model-height) -0.0525))
(from-here
  (move forward (+ (* 0.20 wavelength) 0.0075))
  ;; This differs from the nominal 75 mm lift by less than 2 mm and places
  ;; the bottom face on FFT's perfect-ground half-cell lattice when the panel
  ;; is refined to 5 mm cubes (3 x 20 x 20 cells).
  (move up panel-lift)
  (cuboid name nearby-panel
          size (list 0.015 0.105 0.105)
          material obstruction-material
          anchor center))

(with-scale {0.995 * 1144 / 1296}
  (loop repeat 4 do
        (turn left 90)
        (with-surface slope
          (loop for row from 1 to 5 do
                (from-here
                  (move forward {row * short-unit})
                  (turn left {180 - 45})
                  (with-wire
                    (loop for i from 1 to row do
                          (move forward long-unit))
                    (turn left {180 - 45})
                    (loop for i from 1 to row do
                          (move forward short-unit)
                          (turn left 90)
                          (when (< i row) (move forward short-unit))
                          (turn right 90)))))))

  (turn up 90)
  (from-here
    (with-wire
      (move forward quarter-wave feed start))))

;; Simulate an RG402 mast holding up the antenna, matching the source model.
;(with-wire (move back mast-len))

(nec2c-dielectric-mesh max-kh 0.5 max-cells 1500 max-aspect 1.0)

(show-model)

(module+ main
  (begin
    (define reference-pattern
      (nec2c-radiation-grid
       #:frequency 1296 #:theta-step 2 #:phi-step 2
       #:dielectrics? #f))

    ; (define loaded-pattern-dense
    ;   (nec2c-radiation-grid
    ;    #:frequency 1296 #:theta-step 2 #:phi-step 2
    ;    #:dielectrics? #t
    ;    #:dielectric-solver 'dense
    ;    #:solver-iterations 10000))

    (define loaded-pattern-fft
      (nec2c-radiation-grid
       #:frequency 1296 #:theta-step 2 #:phi-step 2
       #:dielectrics? #t
       #:dielectric-solver 'fft
       #:solver-iterations 10000))

    ;(define loaded-pattern-gmres
    ;  (nec2c-radiation-grid
    ;   #:frequency 1296 #:theta-step 2 #:phi-step 2
    ;   #:dielectrics? #t
    ;   #:dielectric-solver 'gmres
    ;   #:solver-iterations 10000))
    )

  (show-model)
  (show-radiation-comparison
   (list (radiation-case "reference: no dielectric" reference-pattern)
         (radiation-case "loaded: ER=6 panel" loaded-pattern-fft))
   ; (list (radiation-case "dense" loaded-pattern-dense)
   ;       (radiation-case "fft" loaded-pattern-fft)
   ;       (radiation-case "gmres" loaded-pattern-gmres))
   #:aspect-ratio 16/9
   #:palette 'electric
   #:difference? #t
   #:scale 'arrl)
  )
