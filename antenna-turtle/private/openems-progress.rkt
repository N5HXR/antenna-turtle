#lang racket/base

(require racket/class
         racket/format
         racket/gui/base)

(provide make-openems-progress-window)

(define progress-frame%
  (class frame%
    (define/augment (on-close)
      ;; Window-manager close only hides the reporter. Cancellation remains a
      ;; separate, deliberate button action.
      (send this show #f))
    (super-new)))

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
                [height 315]))
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
         (channel-put ready (vector frame phase gauge timestep energy speed))))
     #f))
  (define widgets (channel-get ready))
  (when (exn:fail? widgets) (raise widgets))
  (define frame (vector-ref widgets 0))
  (define phase (vector-ref widgets 1))
  (define gauge (vector-ref widgets 2))
  (define timestep-label (vector-ref widgets 3))
  (define energy-label (vector-ref widgets 4))
  (define speed-label (vector-ref widgets 5))
  (define (enqueue thunk)
    (parameterize ([current-eventspace eventspace])
      (queue-callback thunk #f)))
  (hash
   'cancel-evt (semaphore-peek-evt cancel-requested)
   'update
   (lambda (solver-elapsed current-timestep rate energy-db)
     (enqueue
      (lambda ()
        (send phase set-label "Running FDTD simulation")
        (define fraction
          (min 1.0 (/ current-timestep maximum-timesteps)))
        (send gauge set-value (inexact->exact (round (* 1000 fraction))))
        (send timestep-label set-label
              (format "~a / ~a timesteps (~a%)"
                      current-timestep maximum-timesteps
                      (~r (* 100 fraction) #:precision '(= 1))))
        (send energy-label set-label
              (format "Residual energy: ~a dB; target ~a dB"
                      (~r energy-db #:precision '(= 1))
                      (~r target-energy-db #:precision '(= 1))))
        (send speed-label set-label
              (format "Solver elapsed: ~a   •   speed: ~a MC/s"
                      solver-elapsed (~r rate #:precision '(= 1)))))))
   'phase
   (lambda (text)
     (enqueue (lambda () (send phase set-label text))))
   'close
   (lambda ()
     (enqueue (lambda () (send frame show #f))))))
