#lang racket/base

(require racket/class
         racket/format
         racket/list
         racket/gui/base)

(provide make-openems-progress-window)

(define progress-frame%
  (class frame%
    (define/augment (on-close)
      ;; Window-manager close only hides the reporter. Cancellation remains a
      ;; separate, deliberate button action.
      (send this show #f))
    (super-new)))

(define energy-history-canvas%
  (class canvas%
    (init-field target-energy-db maximum-timesteps)
    (define samples '())
    (define current-excitation-count 1)
    (super-new [min-height 150]
               [stretchable-width #t]
               [stretchable-height #t]
               [style '(border)])
    (define/public (add-sample timestep energy-db excitation-index
                               excitation-count)
      (set! current-excitation-count excitation-count)
      (define global-timestep
        (+ (* (sub1 excitation-index) maximum-timesteps) timestep))
      ;; Keep newest first so adding a status sample remains constant-time.
      (set! samples
            (cons (vector global-timestep energy-db excitation-index)
                  samples))
      (send this refresh))
    (define/override (on-paint)
      (define dc (send this get-dc))
      (define-values (width height) (send dc get-size))
      (define background (make-object color% 8 24 96))
      (define foreground (get-label-foreground-color))
      (define dark-background?
        (< (+ (send background red)
              (send background green)
              (send background blue))
           384))
      (define grid-color
        (if dark-background?
            (make-object color% 90 90 90)
            (make-object color% 205 205 205)))
      (send dc set-background background)
      (send dc clear)
      (send dc set-smoothing 'smoothed)
      (send dc set-text-foreground foreground)
      (define left 48)
      (define right (max (add1 left) (- width 12)))
      (define top 10)
      (define bottom (max (add1 top) (- height 25)))
      (define plot-width (max 1 (- right left)))
      (define plot-height (max 1 (- bottom top)))
      (define observed-min
        (for/fold ([minimum target-energy-db]) ([sample (in-list samples)])
          (min minimum (vector-ref sample 1))))
      ;; Leave one grid interval below the deepest value or target so the
      ;; threshold line never disappears into the canvas border.
      (define axis-min (* 10 (sub1 (floor (/ observed-min 10)))))
      (define safe-axis-min (if (zero? axis-min) -10 axis-min))
      (define maximum-global-timestep
        (max 1
             (if (null? samples)
                 1
                 (vector-ref (first samples) 0))))
      (define (screen-x timestep)
        (+ left (* plot-width (/ timestep maximum-global-timestep))))
      (define (screen-y energy-db)
        (+ top (* plot-height (/ (- (min 0 energy-db))
                                 (- safe-axis-min)))))
      ;; Horizontal 10 dB guides keep the history readable without crowding
      ;; the compact progress window.
      (for ([db (in-range 0 (sub1 safe-axis-min) -10)])
        (define y (screen-y db))
        (send dc set-pen grid-color 1 'solid)
        (send dc draw-line left y right y)
        (send dc draw-text (format "~a" db) 5 (- y 8)))
      (define target-y (screen-y target-energy-db))
      (send dc set-pen (make-object color% 210 70 70) 1 'long-dash)
      (send dc draw-line left target-y right target-y)
      ;; Do not connect the end of one independent excitation to the start of
      ;; the next one. Each excitation gets its own continuous polyline.
      (send dc set-pen (make-object color% 45 255 135) 2 'solid)
      (for ([excitation-index (in-range 1 (add1 current-excitation-count))])
        (define points
          (for/list ([sample (in-list (reverse samples))]
                     #:when (= (vector-ref sample 2) excitation-index))
            (make-object point%
                         (screen-x (vector-ref sample 0))
                         (screen-y (vector-ref sample 1)))))
        (when (pair? points)
          (if (pair? (rest points))
              (send dc draw-lines points)
              (let ([point (first points)])
                (send dc draw-ellipse
                      (- (send point get-x) 1)
                      (- (send point get-y) 1)
                      2 2)))))
      (send dc set-text-foreground foreground)
      (send dc draw-text "0" left (+ bottom 3))
      (define right-label
        (if (> current-excitation-count 1)
            (format "~a total timesteps" maximum-global-timestep)
            (format "~a timesteps" maximum-global-timestep)))
      (define-values (label-width _label-height _descent _space)
        (send dc get-text-extent right-label))
      (send dc draw-text right-label (- right label-width) (+ bottom 3)))))

(define (make-openems-progress-window title maximum-timesteps target-energy-db
                                      artifact-directory)
  (define artifact-directory-text (format "~a" artifact-directory))
  (define eventspace (make-eventspace))
  (define ready (make-channel))
  (define cancel-requested (make-semaphore 0))
  (parameterize ([current-eventspace eventspace])
    (queue-callback
     (lambda ()
       (with-handlers ([exn:fail? (lambda (failure) (channel-put ready failure))])
         (define frame
           (new progress-frame%
                [label "OpenEMS simulation progress"]
                [width 560]
                [height 475]))
         (define root
           (new vertical-panel%
                [parent frame]
                [alignment '(left top)]
                [border 14]
                [spacing 8]))
         (new message%
              [parent root]
              [label (format "Running: ~a" title)]
              [stretchable-width #t])
         (define phase
           (new message%
                [parent root]
                [label "Preparing OpenEMS solver…"]
                [stretchable-width #t]))
         (define gauge
           (new gauge%
                [parent root]
                [label #f]
                [range 1000]
                [stretchable-width #t]))
         (define timestep
           (new message%
                [parent root]
                [label (format "0 / ~a timesteps" maximum-timesteps)]
                [stretchable-width #t]))
         (define energy
           (new message%
                [parent root]
                [label (format "Residual energy: awaiting data; target ~a dB"
                               (~r target-energy-db #:precision '(= 1)))]
                [stretchable-width #t]))
         (define speed
           (new message%
                [parent root]
                [label "Solver elapsed: awaiting data"]
                [stretchable-width #t]))
         (define energy-history
           (new energy-history-canvas%
                [parent root]
                [target-energy-db target-energy-db]
                [maximum-timesteps maximum-timesteps]))
         (new message%
              [parent root]
              [label (format "Artifacts: ~a" artifact-directory-text)]
              [stretchable-width #t])
         (define actions
           (new horizontal-panel%
                [parent root]
                [alignment '(left center)]
                [spacing 8]
                [stretchable-height #f]))
         (define copy-artifacts
           (new button%
                [parent actions]
                [label "Copy artifact path"]
                [callback
                 (lambda (button _event)
                   (with-handlers
                       ([exn:fail?
                         (lambda (_failure)
                           (send button set-label "Could not copy path"))])
                     (send the-clipboard set-clipboard-string
                           artifact-directory-text
                           0)
                     (send button set-label "Artifact path copied")))]))
         (define cancel-simulation
           (new button%
                [parent actions]
                [label "Cancel simulation"]
                [callback
                 (lambda (button _event)
                   (send button enable #f)
                   (send button set-label "Cancelling…")
                   (send phase set-label
                         "Stopping OpenEMS and its child processes…")
                   (semaphore-post cancel-requested))]))
         (new message%
              [parent root]
              [label (string-append
                      "Closing this window only hides it; "
                      "Cancel simulation stops the run.")]
              [stretchable-width #t])
         (send frame show #t)
         (channel-put ready
                      (vector frame phase gauge timestep energy speed
                              energy-history))))
     #f))
  (define widgets (channel-get ready))
  (when (exn:fail? widgets) (raise widgets))
  (define frame (vector-ref widgets 0))
  (define phase (vector-ref widgets 1))
  (define gauge (vector-ref widgets 2))
  (define timestep-label (vector-ref widgets 3))
  (define energy-label (vector-ref widgets 4))
  (define speed-label (vector-ref widgets 5))
  (define energy-history (vector-ref widgets 6))
  (define (enqueue thunk)
    (parameterize ([current-eventspace eventspace])
      (queue-callback thunk #f)))
  (hash
   'cancel-evt (semaphore-peek-evt cancel-requested)
   'update
   (lambda (solver-elapsed current-timestep rate energy-db excitation)
     (enqueue
      (lambda ()
        (define excitation-index (if excitation (first excitation) 1))
        (define excitation-count (if excitation (second excitation) 1))
        (send phase set-label
              (if (> excitation-count 1)
                  (format "Running FDTD excitation ~a of ~a"
                          excitation-index excitation-count)
                  "Running FDTD simulation"))
        (define fraction
          (min 1.0
               (/ (+ (sub1 excitation-index)
                     (/ current-timestep maximum-timesteps))
                  excitation-count)))
        (send gauge set-value (inexact->exact (round (* 1000 fraction))))
        (send timestep-label set-label
              (format "~a / ~a timesteps (~a%)"
                      current-timestep maximum-timesteps
                      (~r (* 100 fraction) #:precision '(= 1))))
        (send energy-label set-label
              (format "Residual energy: ~a dB; target ~a dB"
                      (~r energy-db #:precision '(= 1))
                      (~r target-energy-db #:precision '(= 1))))
        (send energy-history add-sample current-timestep energy-db
              excitation-index excitation-count)
        (send speed-label set-label
              (format "Solver elapsed: ~a   •   speed: ~a MC/s"
                      solver-elapsed (~r rate #:precision '(= 1)))))))
   'phase
   (lambda (text)
     (enqueue (lambda () (send phase set-label text))))
   'close
   (lambda ()
     (enqueue (lambda () (send frame show #f))))))
