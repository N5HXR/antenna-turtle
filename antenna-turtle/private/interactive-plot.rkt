#lang racket/base

;; Racket Plot's public mouse callback replaces its built-in zoom handler.
;; This wrapper instead observes right-button events at the containing canvas,
;; leaving every left-button event to the plot snip unchanged.

(require racket/class
         racket/gui/base
         mrlib/snip-canvas
         pict
         plot
         plot/snip
         "plot-cursor.rkt")

(provide show-interactive-plot)

(define data-cursor-canvas%
  (class snip-canvas%
    (init parent make-snip)
    (init-field series label-proc
                cursor-rule? cursor-fill-color cursor-text-color)

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
            (define label (label-proc selected-series selected-point))
            (define label-renderer
              (if (and (list? label) (andmap string? label))
                  (point-pict
                   plot-point
                   (colorize
                    (apply vl-append
                           2
                           (for/list ([line (in-list label)])
                             (text line null (plot-font-size))))
                    cursor-text-color)
                   #:anchor 'auto
                   #:point-color (cursor-series-color selected-series)
                   #:point-fill-color cursor-fill-color
                   #:point-size 7)
                  (point-label
                   plot-point
                   label
                   #:anchor 'auto
                   #:color cursor-text-color
                   #:point-color (cursor-series-color selected-series)
                   #:point-fill-color cursor-fill-color
                   #:point-size 7)))
            (send snip set-overlay-renderers
                  (append
                   (if cursor-rule?
                       (list
                        (vrule (vector-ref selected-point 0)
                               #:color (cursor-series-color selected-series)
                               #:style 'dot))
                       '())
                   (list label-renderer)))))))

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
                               #:y-label [y-label #f]
                               #:x-min [x-min #f]
                               #:x-max [x-max #f]
                               #:y-min [y-min #f]
                               #:y-max [y-max #f]
                               #:aspect-ratio [aspect-ratio #f]
                               #:legend-anchor [legend-anchor 'bottom-right]
                               #:axes? [axes? #t]
                               #:cursor-rule? [cursor-rule? #t]
                               #:theme [theme 'light])
  (unless (memq theme '(light dark))
    (raise-argument-error
     'show-interactive-plot "(or/c 'light 'dark)" theme))
  (define dark? (eq? theme 'dark))
  (define background (if dark? "black" "white"))
  (define foreground (if dark? "white" "black"))
  (define width (plot-width))
  (define height (plot-height))
  (define frame
    (new frame%
         [label (if title (format "Plot: ~a" title) "Plot")]
         [width (+ width 20)]
         [height (+ height 48)]))
  (define root (new vertical-panel% [parent frame] [spacing 0]))
  (define (make-snip requested-width requested-height)
    (parameterize ([plot-background background]
                   [plot-foreground foreground]
                   [plot-legend-font-size (* 0.6 (plot-font-size))]
                   [plot-x-axis? axes?]
                   [plot-y-axis? axes?]
                   [plot-x-far-axis? axes?]
                   [plot-y-far-axis? axes?])
      (plot-snip renderer-tree
                 #:width requested-width
                 #:height requested-height
                 #:title title
                 #:x-label x-label
                 #:y-label y-label
                 #:x-min x-min
                 #:x-max x-max
                 #:y-min y-min
                 #:y-max y-max
                 #:aspect-ratio aspect-ratio
                 #:legend-anchor legend-anchor)))
  (new data-cursor-canvas%
       [parent root]
       [make-snip make-snip]
       [series series]
       [label-proc label-proc]
       [cursor-rule? cursor-rule?]
       [cursor-fill-color background]
       [cursor-text-color foreground])
  (new message%
       [parent root]
       [label "left drag: zoom  |  left click: unzoom  |  right drag: inspect values"]
       [stretchable-width #t])
  (send frame show #t)
  (void))
