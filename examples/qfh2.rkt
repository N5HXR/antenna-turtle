#lang antenna-turtle

;; A quadrifilar helix for the 915 MHz band. The two loops are crossed,
;; displaced slightly along the antenna axis, and driven 90 degrees apart.

;; -------------------------------------------------------------------------
;; Design parameters
;; -------------------------------------------------------------------------

(define design-frequency 915)
(define tuning-scale 0.524)

(define feed-phases '(0 270))
(define twist-per-step 14)
(define axial-step inch)
(define loop-separation (half centimeter))

(define pattern-angle-step 1)
(define sweep-start 800)
(define sweep-stop 1030)
(define sweep-points 201)

;; -------------------------------------------------------------------------
;; Geometry
;; -------------------------------------------------------------------------

;; Trace one twisted side of a loop and return the endpoint used by its lower
;; crossbar. from-here restores the construction cursor after the side is
;; complete, letting the caller trace its mirror from the same starting point.
(define (trace-helical-leg loop-width target-wire-length)
  (from-here
    (let ([starting-wire-length (wire-used)]
          [lower-end (here)])
      (with-points
        (loop while (< (- (wire-used) starting-wire-length)
                       target-wire-length) do
          (point left (half loop-width))
          (from-here
            (move left (half loop-width))
            (set! lower-end (here)))
          (move down axial-step)
          (turn left twist-per-step)))
      lower-end)))

;; Build one closed bifilar loop: a fed upper crossbar, two twisted sides, and
;; an unfed lower crossbar joining the side endpoints.
(define (build-loop loop-width target-wire-length phase)
  (from-here
    (with-wire
      (spread left loop-width
              feed (center (format "A-~a" phase) 1.0 phase)))

    (let ([first-lower-end
           (trace-helical-leg loop-width target-wire-length)])
      (turn left 180)
      (let ([second-lower-end
             (trace-helical-leg loop-width target-wire-length)])
        ;; Restore the entry orientation before closing the loop. The final
        ;; cursor position does not escape from-here, but its orientation is
        ;; useful while reading and debugging this routine interactively.
        (turn left 180)
        (goto second-lower-end)
        (with-wire
          (goto first-lower-end))))))

(define (build-qfh #:scale [scale tuning-scale]
                   #:frequency [frequency design-frequency])
  (reset-model!)
  (model title "QFH"
         frequency frequency)

  (let ([loop-width (/ wavelength 3)])
    (with-scale scale
      (loop for phase in feed-phases do
        ;; Preserve qfh.rkt's comparison of physically scaled conductor length
        ;; against an unscaled one-third-wave target. As the tuning scale
        ;; shrinks, this produces more turns rather than merely shrinking a
        ;; fixed polygon.
        (build-loop loop-width loop-width phase)
        (turn left 90)
        (move down loop-separation)))))

;; -------------------------------------------------------------------------
;; Analysis helpers
;; -------------------------------------------------------------------------

(define (measure-pattern)
  (nec2c-radiation-grid
   #:theta-step pattern-angle-step
   #:phi-step pattern-angle-step))

(define (measure-sweep [start sweep-start]
                       [stop sweep-stop]
                       [points sweep-points])
  (nec2c-vswr-sweep start stop #:steps points))

;; -------------------------------------------------------------------------
;; Build, measure, and display
;; -------------------------------------------------------------------------

(build-qfh)

(export-mmana "../mmana/qfh2.maa")
(show-model)

(define pattern (measure-pattern))
(show-radiation-pattern-opengl pattern #:palette 'inferno)

(define sweep (measure-sweep))
(show-return-loss-sweep sweep)

;; Other useful views while tuning:
(show-smith-chart sweep)
