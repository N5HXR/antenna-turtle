#lang racket/base

;; Isolated native proof-of-concept shell for the polarization workbench.
;; Keep this deliberately independent of the production radiation viewer: the
;; controls and interaction model will change during M2--M7 experimentation.

(require pict3d
         racket/class
         racket/format
         racket/gui/base
         racket/math
         "measurement-radiation.rkt"
         "nec2c.rkt"
         "nec2c-opengl-view.rkt"
         "visualization-handle.rkt")

(provide show-polarization-surface-poc
         surface-point->angles
         advance-polarization-phase)

(define view-fov-degrees 34)
(define default-azimuth -42.0)
(define default-altitude 24.0)
(define default-zoom 3.1)
(define phase-degrees-per-second 180.0)

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

(define polarization-poc-canvas%
  (class pict3d-canvas%
    (init-field surface view-center radius selection-callback status-label)
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
             "drag to orbit  |  wheel to zoom  |  click to inspect  |  azimuth ~a degrees  elevation ~a degrees"
             (exact-round azimuth) (exact-round altitude)))
      (parameterize ([current-pict3d-background (rgba "black")]
                     [current-pict3d-ambient (emitted "white" 1.0)]
                     [current-pict3d-fov view-fov-degrees])
        (send this set-pict3d
              (camera-scene display-surface view-center radius
                            azimuth altitude zoom))))

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
        (when hit
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
            (update-view!)))))

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
  (define-values (surface radius view-center peak-gain)
    (build-radiation-pict3d
     grid #:scale 'arrl #:palette 'magma #:mesh-step mesh-step))
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
         [label "drag to orbit  |  wheel to zoom  |  click to inspect"]
         [stretchable-width #t]))

  (new message% [parent rail] [label "POLARIZATION WORKBENCH"])
  (define surface-summary
    (new message%
         [parent rail]
         [label (format "POWER SURFACE\nARRL radial scale / magma\npeak ~a"
                        (format-number peak-gain 2 " dBi"))]
         [auto-resize #t]
         [stretchable-width #t]))
  (new message% [parent rail] [label "SELECTED DIRECTION"])
  (define selection-summary
    (new message%
         [parent rail]
         [label "Click the pattern surface\nto inspect an exact direction."]
         [auto-resize #t]
         [stretchable-width #t]))

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
       [label "M2 SHELL\nPolarization color and glyphs\narrive in later milestones."]
       [stretchable-width #t])

  (define canvas #f)
  (define (select-direction! azimuth elevation)
    (define gain
      (gain-at current-grid #:azimuth azimuth #:elevation elevation))
    (define state
      (with-handlers ([exn:fail? (lambda (_failure) #f)])
        (polarization-at current-grid
                         #:azimuth azimuth #:elevation elevation)))
    (send selection-summary set-label
          (string-append
           (format "azimuth     ~a\nelevation   ~a\ngain        ~a"
                   (format-number azimuth 2 " degrees")
                   (format-number elevation 2 " degrees")
                   (format-number gain 2 " dBi"))
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
               [status-label status])))
  (send canvas set-async-updates? #t)

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
     (define-values (new-surface new-radius new-center new-peak)
       (build-radiation-pict3d
        new-grid #:scale 'arrl #:palette 'magma #:mesh-step mesh-step))
     (set! current-grid new-grid)
     (parameterize ([current-eventspace eventspace])
       (queue-callback
        (lambda ()
          (send surface-summary set-label
                (format "POWER SURFACE\nARRL radial scale / magma\npeak ~a"
                        (format-number new-peak 2 " dBi")))
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
