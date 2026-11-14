#lang racket/base

(require pict3d
         rackunit
         racket/class
         racket/gui/base
         racket/list
         racket/math
         "../antenna-turtle/private/nec2c.rkt"
         "../antenna-turtle/private/nec2c-opengl-view.rkt"
         (only-in "../antenna-turtle/private/nec2c-view.rkt"
                  [show-radiation-pattern-opengl
                   show-integrated-radiation-pattern-opengl])
         "../antenna-turtle/private/polarization-poc.rkt"
         "../antenna-turtle/private/visualization-handle.rkt")

(define (check-angle point expected-azimuth expected-elevation)
  (define-values (azimuth elevation)
    (apply surface-point->angles point))
  (check-= azimuth expected-azimuth 1e-10)
  (check-= elevation expected-elevation 1e-10))

(test-case "surface points use public azimuth/elevation directions"
  (check-angle '(1 0 0) 0 0)
  (check-angle '(0 1 0) 90 0)
  (check-angle '(-1 0 0) 180 0)
  (check-angle '(0 -1 0) 270 0)
  (check-angle '(0 0 1) 0 90)
  (check-angle '(0 0 -1) 0 -90)
  (check-angle '(1 1 1) 45 (radians->degrees (asin (/ 1 (sqrt 3))))))

(test-case "RF phase advances, scales, and wraps continuously"
  (check-= (advance-polarization-phase 0 1 1) 180 1e-12)
  (check-= (advance-polarization-phase 350 0.1 1) 8 1e-12)
  (check-= (advance-polarization-phase 10 1 2) 10 1e-12))

(test-case "gain brightness is bounded, nonlinear, and emphasizes strong lobes"
  (check-= (gain->brightness -20 -20 10) 0.1 1e-12)
  (check-= (gain->brightness 10 -20 10) 1.25 1e-12)
  (check-= (gain->brightness -5 -20 10)
           (+ 0.1 (* 1.15 (expt 0.5 1.2))) 1e-12)
  (check-= (gain->brightness -100 -20 10) 0.1 1e-12)
  (check-= (gain->brightness 100 -20 10) 1.25 1e-12)
  (check-= (gain->brightness 3 3 3) 1.0 1e-12))

(define (check-rgb actual expected [epsilon 1e-10])
  (for ([channel (in-list actual)] [wanted (in-list expected)])
    (check-= channel wanted epsilon)))

(test-case "signed circularity has fixed LHCP/linear/RHCP anchors"
  (check-rgb (signed-circularity-color -1) '(255 32 128))
  (check-rgb (signed-circularity-color 0) '(128 255 32))
  (check-rgb (signed-circularity-color 1) '(32 128 255))
  (check-rgb (signed-circularity-color -0.5) '(191.5 143.5 80))
  (check-rgb (signed-circularity-color 0.5) '(80 191.5 143.5))
  (check-rgb (signed-circularity-color #f) '(20 20 26))
  (check-exn exn:fail:contract?
             (lambda () (signed-circularity-color 1.1))))

(test-case "axial-ratio color highlights circular polarization"
  (check-rgb (axial-ratio-color 1) '(255 240 48))
  (check-rgb (axial-ratio-color 2) '(151.5 132 88))
  (check-rgb (axial-ratio-color +inf.0) '(48 24 128))
  (check-rgb (axial-ratio-color #f) '(20 20 26))
  (check-exn exn:fail:contract?
             (lambda () (axial-ratio-color 0.99))))

(define (vector-dot left right)
  (for/sum ([a (in-vector left)] [b (in-vector right)]) (* a b)))

(define (vector-length value)
  (sqrt (vector-dot value value)))

(test-case "polarization glyph frames are tangent and encode tilt and ratio"
  (define linear-frame
    (polarization-glyph-frame-for 90 0 +inf.0 0))
  (check-rgb (vector->list (polarization-glyph-frame-direction linear-frame))
             '(1 0 0))
  (check-rgb (vector->list (polarization-glyph-frame-major-axis linear-frame))
             '(0 0 -1))
  (check-rgb (vector->list (polarization-glyph-frame-minor-axis linear-frame))
             '(0 1 0))
  (check-= (polarization-glyph-frame-minor/major linear-frame) 0 1e-12)
  (define ellipse-frame
    (polarization-glyph-frame-for 90 0 2 45))
  (check-= (polarization-glyph-frame-minor/major ellipse-frame) 0.5 1e-12)
  (check-= (vector-length (polarization-glyph-frame-major-axis ellipse-frame))
           1 1e-12)
  (check-= (vector-length (polarization-glyph-frame-minor-axis ellipse-frame))
           1 1e-12)
  (check-= (vector-dot (polarization-glyph-frame-direction ellipse-frame)
                       (polarization-glyph-frame-major-axis ellipse-frame))
           0 1e-12)
  (check-= (vector-dot (polarization-glyph-frame-major-axis ellipse-frame)
                       (polarization-glyph-frame-minor-axis ellipse-frame))
           0 1e-12)
  (define circle-frame
    (polarization-glyph-frame-for 45 90 1 #f))
  (check-= (polarization-glyph-frame-minor/major circle-frame) 1 1e-12))

(test-case "PoC math rejects undefined directions and bad timing"
  (check-exn #rx"RF origin" (lambda () (surface-point->angles 0 0 0)))
  (check-exn exn:fail:contract?
             (lambda () (advance-polarization-phase 0 -1 1)))
  (check-exn exn:fail:contract?
             (lambda () (advance-polarization-phase 0 1 0))))

(define theta-values '(0 45 90 135 180))
(define phi-values '(0 45 90 135 180 225 270 315))
(define spherical-grid
  (nec2c-pattern-grid
   #f theta-values phi-values
   (for*/list ([theta (in-list theta-values)]
               [phi (in-list phi-values)])
     (nec2c-pattern-sample
      435 theta phi (- 90 theta) phi
      0 0 0 +inf.0 0 'linear 1+0i 0+0i))))

(test-case "glyph sampling preserves cardinals and deduplicates poles"
  (define angles (polarization-glyph-angles spherical-grid 3))
  (check-equal? (count (lambda (angle) (= (car angle) 0)) angles) 1)
  (check-equal? (count (lambda (angle) (= (car angle) 180)) angles) 1)
  (for ([angle (in-list '((90 . 0) (90 . 90) (90 . 180) (90 . 270)))])
    (check-not-false (member angle angles)))
  (check-equal? angles (polarization-glyph-angles spherical-grid 3)))

(define area-sampling-thetas (range 0 181 15))
(define area-sampling-phis (range 0 360 15))
(define area-sampling-grid
  (nec2c-pattern-grid
   #f area-sampling-thetas area-sampling-phis
   (for*/list ([theta (in-list area-sampling-thetas)]
               [phi (in-list area-sampling-phis)])
     (define gain (if (<= theta 75) 0 -30))
     (nec2c-pattern-sample
      435 theta phi (- 90 theta) phi
      0 0 gain 1 #f 'rhcp 1+0i 0-1i))))

(test-case "gain-aware glyph sampling follows displayed lobe area"
  (define angles
    (polarization-glyph-angles-by-gain area-sampling-grid 15))
  (define north-count
    (count (lambda (angle) (<= (car angle) 60)) angles))
  (define south-count
    (count (lambda (angle) (>= (car angle) 120)) angles))
  (check-true (> north-count south-count))
  (for ([angle (in-list '((90 . 0) (90 . 90) (90 . 180) (90 . 270)))])
    (check-not-false (member angle angles)))
  (check-equal?
   angles
   (polarization-glyph-angles-by-gain area-sampling-grid 15)))

(test-case "fixed-size glyphs are omitted rather than detached from nulls"
  (check-true (polarization-glyph-hostable? 1.0 0.05 0.01))
  ;; The displayed lobe itself is smaller than the diagram glyph.
  (check-false (polarization-glyph-hostable? 0.05 0.05 0.01))
  ;; Large lobes tolerate proportionally more absolute clearance.
  (check-true (polarization-glyph-hostable? 1.0 0.05 0.2))
  ;; The same lift would visibly orphan a glyph on a small lobe.
  (check-false (polarization-glyph-hostable? 0.2 0.05 0.051))
  (check-false (polarization-glyph-hostable? 1.0 0.05 0.251))
  (check-exn exn:fail:contract?
             (lambda () (polarization-glyph-hostable? 1.0 0.05 -0.01))))

(define polarization-color-grid
  (nec2c-pattern-grid
   #f '(90) '(0 90 180)
   (list
    (nec2c-pattern-sample
     435 90 0 0 0 0 0 0 1 #f 'rhcp 1+0i 0-1i)
    (nec2c-pattern-sample
     435 90 90 0 90 0 0 0 +inf.0 0 'linear 1+0i 0+0i)
    (nec2c-pattern-sample
     435 90 180 0 180 0 0 0 1 #f 'lhcp 1+0i 0+1i))))

(test-case "surface color cache derives circularity from complex fields"
  (define color-at (make-polarization-color-at polarization-color-grid))
  (check-rgb (color-at 90 0) '(32 128 255))
  (check-rgb (color-at 90 90) '(128 255 32))
  (check-rgb (color-at 90 180) '(255 32 128))
  ;; The cyclic seam resolves to the same RHCP sample as zero degrees.
  (check-rgb (color-at 90 360) '(32 128 255))
  (check-rgb (color-at 45 45) '(20 20 26)))

(test-case "surface color cache can display axial ratio"
  (define color-at
    (make-polarization-color-at
     polarization-color-grid #:mode 'axial-ratio))
  (check-rgb (color-at 90 0) '(255 240 48))
  (check-rgb (color-at 90 90) '(48 24 128))
  (check-rgb (color-at 90 180) '(255 240 48)))

(test-case "far-field inspector uses operator terms and exact polarization"
  (define text
    (polarization-inspector-text polarization-color-grid 0 0 0))
  (check-regexp-match #rx"total gain  0 dBi" text)
  (check-regexp-match #rx"relative    0 dB" text)
  (check-regexp-match #rx"polarization RHCP" text)
  (check-regexp-match #rx"axial ratio  1:1" text)
  (check-regexp-match #rx"tilt angle" text)
  (check-false (regexp-match? #rx"E[_-]?(theta|phi)|Stokes|Jones" text)))

(define gain-brightness-grid
  (nec2c-pattern-grid
   #f '(90) '(0 90 180)
   (for/list ([phi (in-list '(0 90 180))]
              [gain (in-list '(-20 -5 10))])
     (nec2c-pattern-sample
      435 90 phi 0 phi 0 0 gain 1 #f 'rhcp 1+0i 0-1i))))

(test-case "surface color combines polarization hue with gain brightness"
  (define color-at (make-polarization-color-at gain-brightness-grid))
  (define base-rhcp '(32 128 255))
  (check-rgb (color-at 90 0)
             (map (lambda (channel) (* 0.1 channel)) base-rhcp))
  (check-rgb (color-at 90 90)
             (map (lambda (channel)
                    (* (gain->brightness -5 -20 10) channel))
                  base-rhcp))
  (check-rgb (color-at 90 180) '(40 160 255)))

(test-case "camera rays trace the displayed radial surface exactly"
  (define-values (surface _radius _center _peak)
    (build-radiation-pict3d spherical-grid #:mesh-step 45))
  (define hit (trace surface (pos 3 0 0) (dir -1 0 0)))
  (check-not-false hit)
  (check-= (pos-x hit) 1.0 1e-10)
  (check-= (pos-y hit) 0.0 1e-10)
  (check-= (pos-z hit) 0.0 1e-10)
  (define-values (azimuth elevation)
    (surface-point->angles (pos-x hit) (pos-y hit) (pos-z hit)))
  (check-= azimuth 0.0 1e-10)
  (check-= elevation 0.0 1e-10))

(test-case "M5 PoC viewer opens and closes with native glyph controls"
  (define handle
    (show-polarization-surface-poc
     spherical-grid #:width 640 #:height 480 #:mesh-step 45))
  (check-true (visualization-handle? handle))
  (check-true (visualization-open? handle))
  (visualization-update! handle spherical-grid)
  (visualization-close! handle))

(test-case "production radiation entry dispatches to polarization"
  (define handle
    (show-integrated-radiation-pattern-opengl
     spherical-grid #:view 'polarization
     #:width 640 #:height 700 #:mesh-step 45))
  (check-true (visualization-handle? handle))
  (check-true (visualization-open? handle))
  (define viewer-frame
    (for/first ([window (in-list (get-top-level-windows))]
                #:when (and (send window is-shown?)
                            (regexp-match? #rx"polarization workbench$"
                                           (send window get-label))))
      window))
  (check-not-false viewer-frame)
  (define-values (_display-width display-height) (get-display-size))
  (check-true
   (<= (send viewer-frame get-height)
       (min 700 (max 240 (- display-height 80)))))
  (visualization-update! handle spherical-grid)
  (visualization-close! handle))

(test-case "production radiation entry keeps gain as its default view"
  (define handle
    (show-integrated-radiation-pattern-opengl
     spherical-grid #:width 640 #:height 480 #:mesh-step 45))
  (check-true (visualization-handle? handle))
  (check-true (visualization-open? handle))
  (visualization-update! handle spherical-grid)
  (define replacement (visualization-restage! handle))
  (check-true (visualization-handle? replacement))
  (check-true (visualization-open? replacement))
  (visualization-close! handle)
  (visualization-close! replacement))
