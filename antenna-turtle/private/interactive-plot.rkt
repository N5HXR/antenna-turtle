#lang racket/base

;; Racket Plot's public mouse callback replaces its built-in zoom handler.
;; This wrapper instead observes right-button events at the containing canvas,
;; leaving every left-button event to the plot snip unchanged.

(require racket/class
         racket/gui/base
         mrlib/snip-canvas
         plot
         plot/snip
         "plot-cursor.rkt")

(provide show-interactive-plot)

(define data-cursor-canvas%
  (class snip-canvas%
    (init parent make-snip)
    (init-field series label-proc)

    (define/private (update-data-cursor event)
      (define snip (send this get-snip))
      (when snip
        (define editor (send this get-editor))
        (define-values (editor-x editor-y)
          (send editor dc-location-to-editor-location
                (send event get-x)
                (send event get-y)))
        (define snip-x (box 0))
        (define snip-y (box 0))
        (when (send editor get-snip-location snip snip-x snip-y)
          (define local-x (- editor-x (unbox snip-x)))
          (define local-y (- editor-y (unbox snip-y)))
          (define selection
            (nearest-cursor-sample
             series local-x local-y
             (lambda (point) (send snip plot->dc point))))
          (when selection
            (define selected-series
              (cursor-selection-series selection))
            (define selected-point
              (cursor-selection-point selection))
            (define plot-point
              (vector (vector-ref selected-point 0)
                      (vector-ref selected-point 1)))
            (send snip set-overlay-renderers
                  (list
                   (vrule (vector-ref selected-point 0)
                          #:color (cursor-series-color selected-series)
                          #:style 'dot)
                   (point-label
                    plot-point
                    (label-proc selected-series selected-point)
                    #:anchor 'auto
                    #:point-color (cursor-series-color selected-series)
                    #:point-fill-color "white"
                    #:point-size 7)))))))

    (define/override (on-event event)
      (define event-type (send event get-event-type))
      (cond
        [(eq? event-type 'right-down)
         (update-data-cursor event)]
        [(and (eq? event-type 'motion)
              (send event get-right-down))
         (update-data-cursor event)]
        ;; Leave the most recent label pinned when the button is released.
        [(eq? event-type 'right-up) (void)]
        ;; Plot receives left-button events exactly as before, retaining its
        ;; click-and-drag zoom and click-to-unzoom behavior.
        [else (super on-event event)]))

    (super-new [parent parent]
               [make-snip make-snip]
               [horiz-margin 5]
               [vert-margin 5]
               [horizontal-inset 5]
               [vertical-inset 5])))

(define (show-interactive-plot renderer-tree series label-proc
                               #:title [title #f]
                               #:x-label [x-label #f]
                               #:y-label [y-label #f])
  (define width (plot-width))
  (define height (plot-height))
  (define frame
    (new frame%
         [label (if title (format "Plot: ~a" title) "Plot")]
         [width (+ width 20)]
         [height (+ height 48)]))
  (define root (new vertical-panel% [parent frame] [spacing 0]))
  (define (make-snip requested-width requested-height)
    (plot-snip renderer-tree
               #:width requested-width
               #:height requested-height
               #:title title
               #:x-label x-label
               #:y-label y-label))
  (new data-cursor-canvas%
       [parent root]
       [make-snip make-snip]
       [series series]
       [label-proc label-proc])
  (new message%
       [parent root]
       [label "left drag: zoom  |  left click: unzoom  |  right drag: inspect values"]
       [stretchable-width #t])
  (send frame show #t)
  (void))
