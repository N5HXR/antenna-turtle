#lang racket/base

;; Isolated native proof-of-concept shell for the polarization workbench.
;; Keep this deliberately independent of the production radiation viewer: the
;; controls and interaction model will change during M2--M7 experimentation.

(require pict3d
         racket/class
         racket/format
         racket/gui/base
         racket/list
         racket/math
         "measurement-radiation.rkt"
         "nec2c.rkt"
         "nec2c-opengl-view.rkt"
         "visualization-handle.rkt")

(provide show-polarization-surface-poc
         surface-point->angles
         advance-polarization-phase
         signed-circularity-color
         axial-ratio-color
         make-polarization-color-at
         gain->brightness)

(define view-fov-degrees 34)
(define default-azimuth -42.0)
(define default-altitude 24.0)
(define default-zoom 3.1)
(define phase-degrees-per-second 180.0)

;; Gain owns brightness while polarization owns hue. This is an exposure
;; scale rather than darkening alone: high-gain colors are boosted above their
;; authored RGB anchors, while the floor keeps weak lobes visible. The strong
;; exponent opens up contrast within the larger lobes.
(define polarization-brightness-floor 0.1)
(define polarization-brightness-ceiling 1.25)
(define polarization-brightness-exponent 1.2)

;; Frozen M3 palette. Each anchor contains the same three channel levels in a
;; different order, preserving vivid transitions without passing through gray.
(define lhcp-color '(255 32 128))
(define linear-color '(128 255 32))
(define rhcp-color '(32 128 255))
(define undefined-polarization-color '(20 20 26))
(define linear-axial-ratio-color '(48 24 128))
(define circular-axial-ratio-color '(255 240 48))
(define polarization-surface-modes '(signed-circularity axial-ratio))

(define (interpolate-rgb left right fraction)
  (for/list ([a (in-list left)] [b (in-list right)])
    (+ a (* fraction (- b a)))))

(define (signed-circularity-color circularity)
  (unless (or (not circularity)
              (and (real? circularity) (<= -1 circularity 1)))
    (raise-argument-error
     'signed-circularity-color "(or/c #f (real-in -1 1))" circularity))
  (cond
    [(not circularity) undefined-polarization-color]
    [(negative? circularity)
     (interpolate-rgb lhcp-color linear-color (+ circularity 1.0))]
    [else
     (interpolate-rgb linear-color rhcp-color circularity)]))

(define (axial-ratio-color ratio)
  (unless (or (not ratio)
              (and (real? ratio) (>= ratio 1)))
    (raise-argument-error
     'axial-ratio-color "(or/c #f (real-in 1 +inf.0))" ratio))
  (if (not ratio)
      undefined-polarization-color
      (interpolate-rgb
       linear-axial-ratio-color circular-axial-ratio-color
       (if (infinite? ratio) 0.0 (/ 1.0 ratio)))))

(define (gain->brightness gain minimum-gain maximum-gain)
  (unless (andmap real? (list gain minimum-gain maximum-gain))
    (raise-arguments-error
     'gain->brightness "gain bounds must be real"
     "gain" gain "minimum gain" minimum-gain "maximum gain" maximum-gain))
  (when (> minimum-gain maximum-gain)
    (raise-arguments-error
     'gain->brightness "minimum gain exceeds maximum gain"
     "minimum gain" minimum-gain "maximum gain" maximum-gain))
  (if (= minimum-gain maximum-gain)
      1.0
      (let* ([normalized
              (max 0.0
                   (min 1.0
                        (/ (- gain minimum-gain)
                           (- maximum-gain minimum-gain))))]
             [curved (expt normalized polarization-brightness-exponent)])
        (+ polarization-brightness-floor
           (* (- polarization-brightness-ceiling
                 polarization-brightness-floor)
              curved)))))

(define (finite-real? value)
  (and (real? value) (< -inf.0 value +inf.0)))

(define (total-gain-range grid)
  (define gains
    (filter finite-real?
            (map nec2c-pattern-sample-total-gain-db
                 (nec2c-pattern-grid-samples grid))))
  (if (null? gains)
      (values 0.0 0.0)
      (values (apply min gains) (apply max gains))))

(define (scale-rgb rgb brightness)
  (map (lambda (channel) (min 255.0 (* channel brightness))) rgb))

(define (polarization-angle-key theta phi)
  (define normalized-phi
    (- phi (* 360.0 (floor (/ phi 360.0)))))
  (cons (inexact->exact (round (* theta 1000000)))
        (inexact->exact (round (* normalized-phi 1000000)))))

(define (make-polarization-color-at grid
                                    #:mode [mode 'signed-circularity])
  (unless (nec2c-pattern-grid? grid)
    (raise-argument-error
     'make-polarization-color-at "nec2c-pattern-grid?" grid))
  (unless (memq mode polarization-surface-modes)
    (raise-argument-error
     'make-polarization-color-at
     "(or/c 'signed-circularity 'axial-ratio)" mode))
  ;; The surface constructor visits only sampled angular vertices. Analyze
  ;; each solver sample once so polarization coloring remains linear in grid
  ;; size instead of repeatedly searching the grid during triangulation.
  (define colors (make-hash))
  (define-values (minimum-gain maximum-gain) (total-gain-range grid))
  (for ([sample (in-list (nec2c-pattern-grid-samples grid))])
    (define state
      (with-handlers ([exn:fail? (lambda (_failure) #f)])
        (analyze-polarization (nec2c-pattern-sample-e-theta sample)
                              (nec2c-pattern-sample-e-phi sample))))
    (define gain
      (let ([sample-gain (nec2c-pattern-sample-total-gain-db sample)])
        (if (finite-real? sample-gain) sample-gain minimum-gain)))
    (define hue
      (cond
        [(eq? mode 'signed-circularity)
         (signed-circularity-color
          (and state (polarization-state-signed-circularity state)))]
        [else
         (axial-ratio-color
          (and state (polarization-state-axial-ratio state)))]))
    (hash-set!
     colors
     (polarization-angle-key
      (nec2c-pattern-sample-theta-deg sample)
      (nec2c-pattern-sample-phi-deg sample))
     (scale-rgb hue
                (gain->brightness gain minimum-gain maximum-gain))))
  (lambda (theta phi)
    (if (and (real? theta) (real? phi))
        (hash-ref colors (polarization-angle-key theta phi)
                  undefined-polarization-color)
        undefined-polarization-color)))

(define (normalize-degrees degrees)
  (- degrees (* 360.0 (floor (/ degrees 360.0)))))

(define (advance-polarization-phase phase elapsed-seconds speed)
  (unless (real? phase)
    (raise-argument-error 'advance-polarization-phase "real?" phase))
  (unless (and (real? elapsed-seconds) (>= elapsed-seconds 0))
    (raise-argument-error
     'advance-polarization-phase "nonnegative-real?" elapsed-seconds))
  (unless (and (real? speed) (positive? speed))
    (raise-argument-error 'advance-polarization-phase "positive-real?" speed))
  (normalize-degrees
   (+ phase (* phase-degrees-per-second elapsed-seconds speed))))

;; Radiation surfaces are radial about the RF origin even though the camera is
;; framed around the surface bounds. Convert an exact traced surface point to
;; the public azimuth/elevation convention used by gain-at and polarization-at.
(define (surface-point->angles x y z)
  (unless (andmap real? (list x y z))
    (raise-arguments-error
     'surface-point->angles "coordinates must be real"
     "x" x "y" y "z" z))
  (define radius (sqrt (+ (sqr x) (sqr y) (sqr z))))
  (when (< radius 1e-12)
    (raise-arguments-error
     'surface-point->angles "the RF origin has no angular direction"
     "point" (vector x y z)))
  (values (if (and (zero? x) (zero? y))
              0.0
              (normalize-degrees (radians->degrees (atan y x))))
          (radians->degrees (asin (max -1.0 (min 1.0 (/ z radius)))))))

(define (camera-affine view-center radius azimuth altitude zoom)
  (define az (degrees->radians azimuth))
  (define alt (degrees->radians altitude))
  (define distance (* radius zoom))
  (point-at
   (pos (+ (pos-x view-center) (* distance (cos alt) (cos az)))
        (+ (pos-y view-center) (* distance (cos alt) (sin az)))
        (+ (pos-z view-center) (* distance (sin alt))))
   view-center))

(define (camera-scene surface view-center radius azimuth altitude zoom)
  (combine surface
           (basis 'camera
                  (camera-affine view-center radius azimuth altitude zoom))))

(define (backend-title grid)
  (define run (nec2c-pattern-grid-run grid))
  (if (and (hash? run) (eq? (hash-ref run 'backend #f) 'openems))
      "OpenEMS"
      "NEC2C"))

(define (format-number value digits [suffix ""])
  (if (real? value)
      (format "~a~a" (~r (exact->inexact value) #:precision digits) suffix)
      "unavailable"))

(define (format-ratio ratio)
  (cond [(not ratio) "undefined"]
        [(infinite? ratio) "linear (infinite)"]
        [else (format-number ratio 2 ":1")]))

(define (format-tilt tilt)
  (if tilt (format-number tilt 1 " degrees") "undefined"))

(define polarization-legend-canvas%
  (class canvas%
    (init-field [mode 'signed-circularity])
    (super-new [min-width 276] [min-height 86]
               [stretchable-width #t] [stretchable-height #f])
    (define/public (set-mode new-mode)
      (set! mode new-mode)
      (send this refresh))
    (define/override (on-paint)
      (define dc (send this get-dc))
      (define-values (width height) (send this get-client-size))
      (define left 8)
      (define right (max (+ left 1) (- width 8)))
      (define top 24)
      (define bar-height 18)
      (send dc set-pen "transparent" 0 'transparent)
      (for ([x (in-range left right)])
        (define fraction (/ (- x left) (max 1 (- right left 1))))
        (define rgb
          (if (eq? mode 'signed-circularity)
              (signed-circularity-color (- (* 2.0 fraction) 1.0))
              (axial-ratio-color
               (if (zero? fraction) +inf.0 (/ 1.0 fraction)))))
        (send dc set-brush
              (make-object color%
                           (exact-round (first rgb))
                           (exact-round (second rgb))
                           (exact-round (third rgb)))
              'solid)
        (send dc draw-rectangle x top 1 bar-height))
      (send dc set-text-foreground "black")
      (define left-label
        (if (eq? mode 'signed-circularity) "LHCP" "LINEAR"))
      (define center-label
        (if (eq? mode 'signed-circularity) "LINEAR" "ELLIPTICAL"))
      (define right-label
        (if (eq? mode 'signed-circularity) "RHCP" "CIRCULAR"))
      (send dc draw-text left-label left 2)
      (define-values (center-width _h _d _s)
        (send dc get-text-extent center-label))
      (send dc draw-text center-label (- (/ width 2) (/ center-width 2)) 2)
      (define-values (right-width _rh _rd _rs)
        (send dc get-text-extent right-label))
      (send dc draw-text right-label (- right right-width) 2)
      (define left-value
        (if (eq? mode 'signed-circularity) "-1" "infinite:1"))
      (define center-value (if (eq? mode 'signed-circularity) "0" "2:1"))
      (define right-value (if (eq? mode 'signed-circularity) "+1" "1:1"))
      (send dc draw-text left-value left (+ top bar-height 4))
      (define-values (center-value-width _cvh _cvd _cvs)
        (send dc get-text-extent center-value))
      (send dc draw-text center-value
            (- (/ width 2) (/ center-value-width 2))
            (+ top bar-height 4))
      (define-values (right-value-width _rvh _rvd _rvs)
        (send dc get-text-extent right-value))
      (send dc draw-text right-value (- right right-value-width)
            (+ top bar-height 4)))))

(define polarization-poc-canvas%
  (class pict3d-canvas%
    (init-field surface view-center radius selection-callback
                selection-cleared-callback status-label)
    (define azimuth default-azimuth)
    (define altitude default-altitude)
    (define zoom default-zoom)
    (define dragging? #f)
    (define moved? #f)
    (define previous-x 0)
    (define previous-y 0)
    (define down-x 0)
    (define down-y 0)
    (define selection-marker empty-pict3d)
    ;; Camera motion must never rebuild the triangle scene. Pict3D surface
    ;; freezing is substantially more expensive than replacing the camera
    ;; basis, and doing it for every queued mouse-motion event makes an orbit
    ;; continue long after the button is released.
    (define display-surface surface)
    (super-new
     [pict3d (camera-scene display-surface view-center
                           radius azimuth altitude zoom)])

    (define/private (update-view!)
      (send status-label set-label
            (format
             "drag to orbit  |  wheel to zoom  |  click surface to inspect  |  click background to clear  |  azimuth ~a degrees  elevation ~a degrees"
             (exact-round azimuth) (exact-round altitude)))
      (parameterize ([current-pict3d-background (rgba "black")]
                     [current-pict3d-ambient (emitted "white" 1.0)]
                     [current-pict3d-fov view-fov-degrees])
        (send this set-pict3d
              (camera-scene display-surface view-center radius
                            azimuth altitude zoom))))

    (define/private (clear-selection!)
      (set! selection-marker empty-pict3d)
      (set! display-surface surface)
      (selection-cleared-callback)
      (update-view!))

    (define/private (select-at! x y)
      (define-values (width height) (send this get-client-size))
      (when (and (> width 0) (> height 0))
        (define camera
          (camera-affine view-center radius azimuth altitude zoom))
        (define ray-direction
          ((camera-ray-dir camera
                           #:width width #:height height
                           #:fov view-fov-degrees)
           x y))
        ;; Trace only the data surface, never the selection marker.
        (define hit (trace surface (affine-origin camera) ray-direction))
        (if hit
            (with-handlers ([exn:fail:contract? (lambda (_failure) (void))])
              (define-values (selected-azimuth selected-elevation)
                (surface-point->angles (pos-x hit) (pos-y hit) (pos-z hit)))
              (set! selection-marker
                    (freeze
                     (with-color (rgba 1.0 1.0 1.0 1.0)
                       (with-emitted (emitted 1.0 1.0 1.0 1.0)
                         (sphere hit (* radius 0.022))))))
              (set! display-surface
                    (freeze (combine surface selection-marker)))
              (selection-callback selected-azimuth selected-elevation)
              (update-view!))
            (clear-selection!))))

    (define/public (replace-surface! new-surface new-center new-radius)
      (set! surface new-surface)
      (set! view-center new-center)
      (set! radius new-radius)
      (set! selection-marker empty-pict3d)
      (set! display-surface surface)
      (update-view!))

    (define/override (on-event event)
      (define type (send event get-event-type))
      (define x (send event get-x))
      (define y (send event get-y))
      (case type
        [(left-down)
         (set! dragging? #t)
         (set! moved? #f)
         (set! down-x x)
         (set! down-y y)
         (set! previous-x x)
         (set! previous-y y)]
        [(left-up)
         (when (and dragging? (not moved?)) (select-at! x y))
         (set! dragging? #f)]
        [(motion)
         (when dragging?
           (when (or (> (abs (- x down-x)) 3) (> (abs (- y down-y)) 3))
             (set! moved? #t))
           (when moved?
             (set! azimuth (- azimuth (* 0.45 (- x previous-x))))
             (set! altitude
                   (max -89.0
                        (min 89.0
                             (+ altitude (* 0.45 (- y previous-y))))))
             (set! previous-x x)
             (set! previous-y y)
             (update-view!)))]
        [(wheel-up)
         (set! zoom (max 1.25 (* zoom 0.88)))
         (update-view!)]
        [(wheel-down)
         (set! zoom (min 20.0 (/ zoom 0.88)))
         (update-view!)]
        [else (void)]))

    (define/override (on-char event)
      (case (send event get-key-code)
        [(wheel-up #\+)
         (set! zoom (max 1.25 (* zoom 0.88)))
         (update-view!)]
        [(wheel-down #\-)
         (set! zoom (min 20.0 (/ zoom 0.88)))
         (update-view!)]
        [else (void)]))))

(define (show-polarization-surface-poc grid
                                       #:width [width 1180]
                                       #:height [height 780]
                                       #:mesh-step [mesh-step 2])
  (unless (nec2c-pattern-grid? grid)
    (raise-argument-error
     'show-polarization-surface-poc "nec2c-pattern-grid?" grid))
  (unless (and (exact-integer? width) (positive? width))
    (raise-argument-error
     'show-polarization-surface-poc "exact-positive-integer?" width))
  (unless (and (exact-integer? height) (positive? height))
    (raise-argument-error
     'show-polarization-surface-poc "exact-positive-integer?" height))
  (unless (and (real? mesh-step) (positive? mesh-step))
    (raise-argument-error 'show-polarization-surface-poc
                          "positive-real?" mesh-step))

  (define current-grid grid)
  (define current-surface-mode 'signed-circularity)
  (define initial-color-at
    (make-polarization-color-at grid #:mode current-surface-mode))
  (define-values (minimum-gain maximum-gain) (total-gain-range grid))
  (define-values (surface radius view-center _peak-gain)
    (build-radiation-pict3d
     grid #:scale 'arrl #:mesh-step mesh-step #:color-at initial-color-at))
  (define frame
    (new frame%
         [label (format "~a polarization workbench PoC"
                        (backend-title grid))]
         [width width]
         [height height]))
  (define eventspace (current-eventspace))
  (define root (new vertical-panel% [parent frame]))
  (define body (new horizontal-panel% [parent root]))
  (define viewport (new vertical-panel% [parent body]))
  (define rail
    (new vertical-panel%
         [parent body]
         [min-width 300]
         [stretchable-width #f]
         [alignment '(left top)]
         [vert-margin 12]
         [horiz-margin 12]
         [spacing 10]))
  (define footer
    (new horizontal-panel%
         [parent root]
         [stretchable-height #f]
         [alignment '(left center)]))
  (define status
    (new message%
         [parent footer]
         [label "drag to orbit  |  wheel to zoom  |  click surface to inspect  |  click background to clear"]
         [stretchable-width #t]))

  (define (surface-mode-title)
    (if (eq? current-surface-mode 'signed-circularity)
        "SIGNED CIRCULARITY"
        "AXIAL RATIO"))

  (define (surface-summary-text minimum maximum)
    (format
     "~a SURFACE\nARRL radius from total gain\nbrightness ~a to ~a"
     (surface-mode-title)
     (format-number minimum 2 " dBi")
     (format-number maximum 2 " dBi")))

  (new message% [parent rail] [label "POLARIZATION WORKBENCH"])
  (define surface-summary
    (new message%
         [parent rail]
         [label (surface-summary-text minimum-gain maximum-gain)]
         [auto-resize #t]
         [stretchable-width #t]))
  (define canvas #f)
  (define surface-rebuild-timer #f)
  (define (schedule-surface-rebuild!)
    (when surface-rebuild-timer
      (send surface-rebuild-timer stop)
      (send surface-rebuild-timer start 120 #t)))
  (new message% [parent rail] [label "SURFACE"])
  (new choice%
       [parent rail]
       [label #f]
       [choices '("SIGNED CIRCULARITY" "AXIAL RATIO")]
       [selection 0]
       [callback
        (lambda (choice _event)
          (set! current-surface-mode
                (if (zero? (send choice get-selection))
                    'signed-circularity
                    'axial-ratio))
          (schedule-surface-rebuild!))])
  (define legend
    (new polarization-legend-canvas%
         [parent rail]
         [mode current-surface-mode]))
  (new message%
       [parent rail]
       [label (string-append
               "Sense is viewed from behind the antenna,\n"
               "looking outward along propagation.\n"
               "Clockwise field rotation is RHCP.")]
       [stretchable-width #t])
  (new message% [parent rail] [label "SELECTED DIRECTION"])
  (define selection-summary
    (new message%
         [parent rail]
         [label "Click the pattern surface\nto inspect an exact direction."]
         [auto-resize #t]
         [stretchable-width #t]))

  (define (clear-selection!)
    (send selection-summary set-label
          "Click the pattern surface\nto inspect an exact direction."))

  (define phase 0.0)
  (define speed 1.0)
  (define playing? #t)
  (define last-tick (current-inexact-milliseconds))
  (new message% [parent rail] [label "RF PHASE"])
  (define phase-label
    (new message% [parent rail] [label "0 degrees"]
         [auto-resize #t] [stretchable-width #t]))
  (define phase-slider #f)
  (set! phase-slider
        (new slider%
             [parent rail]
             [label #f]
             [min-value 0]
             [max-value 359]
             [init-value 0]
             [callback
              (lambda (control _event)
                (set! phase (send control get-value))
                (send phase-label set-label
                      (format "~a degrees" (exact-round phase))))]))
  (define playback-row
    (new horizontal-panel%
         [parent rail]
         [stretchable-height #f]
         [alignment '(left center)]))
  (define play-button #f)
  (set! play-button
        (new button%
             [parent playback-row]
             [label "PAUSE"]
             [callback
              (lambda (button _event)
                (set! playing? (not playing?))
                (set! last-tick (current-inexact-milliseconds))
                (send button set-label (if playing? "PAUSE" "PLAY")))]))
  (define speed-label
    (new message% [parent playback-row] [label "speed 1.00x"]))
  (new slider%
       [parent rail]
       [label #f]
       [min-value 10]
       [max-value 400]
       [init-value 100]
       [callback
        (lambda (control _event)
          (set! speed (/ (send control get-value) 100.0))
          (send speed-label set-label
                (format "speed ~ax" (~r speed #:precision 2))))])
  (new message%
       [parent rail]
       [label "M4 SURFACE METRICS\nSigned circularity and axial ratio\nacross the complete gain range."]
       [stretchable-width #t])

  (define (select-direction! azimuth elevation)
    (define gain
      (gain-at current-grid #:azimuth azimuth #:elevation elevation))
    (define state
      (with-handlers ([exn:fail? (lambda (_failure) #f)])
        (polarization-at current-grid
                         #:azimuth azimuth #:elevation elevation)))
    (send selection-summary set-label
          (string-append
           (format "azimuth     ~a\nelevation   ~a\ngain        ~a\nrelative    ~a"
                   (format-number azimuth 2 " degrees")
                   (format-number elevation 2 " degrees")
                   (format-number gain 2 " dBi")
                   (format-number (- gain maximum-gain) 2 " dB"))
           (if state
               (format "\nsense       ~a\naxial ratio ~a\ntilt        ~a"
                       (string-upcase
                        (symbol->string (polarization-state-sense state)))
                       (format-ratio
                        (polarization-state-axial-ratio state))
                       (format-tilt
                        (polarization-state-tilt-deg state)))
               "\npolarization unavailable"))))

  (parameterize ([current-pict3d-background (rgba "black")]
                 [current-pict3d-ambient (emitted "white" 1.0)]
                 [current-pict3d-fov view-fov-degrees])
    (set! canvas
          (new polarization-poc-canvas%
               [parent viewport]
               [surface surface]
               [view-center view-center]
               [radius radius]
               [selection-callback select-direction!]
               [selection-cleared-callback clear-selection!]
               [status-label status])))
  (send canvas set-async-updates? #t)

  (define (rebuild-surface!)
    (define color-at
      (make-polarization-color-at current-grid #:mode current-surface-mode))
    (define-values (new-surface new-radius new-center _new-peak)
      (build-radiation-pict3d
       current-grid #:scale 'arrl #:mesh-step mesh-step #:color-at color-at))
    (send legend set-mode current-surface-mode)
    (send surface-summary set-label
          (surface-summary-text minimum-gain maximum-gain))
    (clear-selection!)
    (send canvas replace-surface! new-surface new-center new-radius))

  (set! surface-rebuild-timer
        (new timer%
             [notify-callback rebuild-surface!]))

  (define timer
    (new timer%
         [interval 33]
         [notify-callback
          (lambda ()
            (cond
              [(not (send frame is-shown?)) (send timer stop)]
              [else
               (define now (current-inexact-milliseconds))
               (define elapsed (/ (- now last-tick) 1000.0))
               (set! last-tick now)
               (when playing?
                 (set! phase
                       (advance-polarization-phase phase elapsed speed))
                 (define displayed (modulo (exact-round phase) 360))
                 (send phase-slider set-value displayed)
                 (send phase-label set-label
                       (format "~a degrees" displayed)))]))]))

  (send frame show #t)
  (make-visualization-handle
   (lambda (new-grid)
     (unless (nec2c-pattern-grid? new-grid)
       (raise-argument-error
        'visualization-update! "nec2c-pattern-grid?" new-grid))
     (define new-color-at
       (make-polarization-color-at new-grid #:mode current-surface-mode))
     (define-values (new-minimum-gain new-maximum-gain)
       (total-gain-range new-grid))
     (define-values (new-surface new-radius new-center _new-peak)
       (build-radiation-pict3d
        new-grid #:scale 'arrl #:mesh-step mesh-step
        #:color-at new-color-at))
     (set! current-grid new-grid)
     (set! minimum-gain new-minimum-gain)
     (set! maximum-gain new-maximum-gain)
     (parameterize ([current-eventspace eventspace])
       (queue-callback
        (lambda ()
          (send surface-summary set-label
                (surface-summary-text new-minimum-gain new-maximum-gain))
          (send selection-summary set-label
                "Click the pattern surface\nto inspect an exact direction.")
          (send canvas replace-surface! new-surface new-center new-radius))
        #f)))
   (lambda ()
     (parameterize ([current-eventspace eventspace])
       (queue-callback (lambda ()
                         (set! last-tick (current-inexact-milliseconds))
                         (send frame show #t)
                         (send timer start 33))
                       #f)))
   (lambda ()
     (parameterize ([current-eventspace eventspace])
       (queue-callback (lambda ()
                         (send timer stop)
                         (send frame show #f))
                       #f)))
   (lambda () (send frame is-shown?))))
