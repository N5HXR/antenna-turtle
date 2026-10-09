#lang racket/base

;; Racket Plot3D deliberately fits the rotated horizontal and vertical view
;; extents independently. That fills the viewport, but it also changes the
;; apparent proportions of a solid as the view rotates. This small adapter
;; retains Plot3D's renderer and interactive snip while choosing a new plot
;; area aspect ratio for every angle/altitude pair, giving both screen axes the
;; same scale.

(require racket/class
         racket/gui/base
         racket/math
         racket/match
         plot/utils
         plot/private/common/draw
         plot/private/common/parameter-group
         plot/private/gui/lazy-snip-untyped
         plot/private/no-gui/plot3d-utils
         plot/private/plot3d/plot-area)

(provide show-proportional-plot3d)

(define (uniform-view-aspect angle altitude aspect-multiplier)
  (define theta (* pi (/ angle 180)))
  (define rho (* pi (/ altitude 180)))
  ;; Plot normalizes each data axis to a unit cube before rotating it. The
  ;; following are the projected width and height of that cube.
  (define horizontal-span
    (+ (abs (cos theta)) (abs (sin theta))))
  (define vertical-span
    (+ (* (abs (sin rho)) horizontal-span)
       (abs (cos rho))))
  (* aspect-multiplier (/ horizontal-span vertical-span)))

(define (show-proportional-plot3d/current-eventspace
         renderer-tree
         #:x-min [x-min #f] #:x-max [x-max #f]
         #:y-min [y-min #f] #:y-max [y-max #f]
         #:z-min [z-min #f] #:z-max [z-max #f]
         #:width [width (plot-width)]
         #:height [height (plot-height)]
         #:angle [angle (plot3d-angle)]
         #:altitude [altitude (plot3d-altitude)]
         #:title [title (plot-title)]
         #:x-label [x-label (plot-x-label)]
         #:y-label [y-label (plot-y-label)]
         #:z-label [z-label (plot-z-label)]
         #:aspect-multiplier [aspect-multiplier 1]
         #:legend-anchor [legend-anchor (plot-legend-anchor)])
  (parameterize ([plot-title title]
                 [plot-x-label x-label]
                 [plot-y-label y-label]
                 [plot-z-label z-label]
                 [plot-legend-anchor legend-anchor])
    (define saved-plot-parameters (plot-parameters))
    (define renderer-list (get-renderer-list renderer-tree))
    (define bounds-rect
      (get-bounds-rect renderer-list
                       x-min x-max y-min y-max z-min z-max))
    (define-values
      (x-ticks x-far-ticks y-ticks y-far-ticks z-ticks z-far-ticks)
      (get-ticks renderer-list bounds-rect))
    (define legend (get-legend-entry-list renderer-list bounds-rect))
    (define render-tasks-hash (make-hash))

    (define (make-bitmap-and-area animating? angle altitude width height)
      (parameterize/group
       ([plot-parameters saved-plot-parameters]
        [plot-animating? (if animating? #t (plot-animating?))]
        [plot3d-angle angle]
        [plot3d-altitude altitude])
       (define bitmap
         (make-bitmap width height #t
                      #:backing-scale
                      (or (get-display-backing-scale) 1.0)))
       (define dc (new bitmap-dc% [bitmap bitmap]))
       (define dynamic-aspect
         (uniform-view-aspect angle altitude aspect-multiplier))
       (define area
         (new 3d-plot-area%
              [bounds-rect bounds-rect]
              [rx-ticks x-ticks]
              [rx-far-ticks x-far-ticks]
              [ry-ticks y-ticks]
              [ry-far-ticks y-far-ticks]
              [rz-ticks z-ticks]
              [rz-far-ticks z-far-ticks]
              [legend legend]
              [dc dc]
              [dc-x-min 0]
              [dc-y-min 0]
              [dc-x-size width]
              [dc-y-size height]
              [aspect-ratio dynamic-aspect]))
       (send area start-plot)
       (cond
         [(not (hash-ref render-tasks-hash (plot-animating?) #f))
          (for ([renderer (in-list renderer-list)])
            (match-define
              (renderer3d renderer-bounds _bounds-fun _ticks-fun
                          _label-proc render-proc)
              renderer)
            (when render-proc
              (send area start-renderer
                    (if renderer-bounds
                        (rect-inexact->exact renderer-bounds)
                        (unknown-rect 3)))
              (render-proc area)))
          (hash-set! render-tasks-hash
                     (plot-animating?)
                     (send area get-render-tasks))]
         [else
          (send area set-render-tasks
                (hash-ref render-tasks-hash (plot-animating?)))])
       (send area end-renderers)
       (send area end-plot)
       (values bitmap area)))

    (define (make-snip requested-width requested-height)
      (define-values (bitmap area)
        (make-bitmap-and-area
         #f angle altitude requested-width requested-height))
      (make-3d-plot-snip
       bitmap saved-plot-parameters make-bitmap-and-area
       angle altitude area requested-width requested-height))

    (define frame
      (make-snip-frame
       make-snip width height
       (if title (format "Plot: ~a" title) "Plot")))
    (send frame show #t)
    (void)))

(define (show-proportional-plot3d
         renderer-tree
         #:x-min [x-min #f] #:x-max [x-max #f]
         #:y-min [y-min #f] #:y-max [y-max #f]
         #:z-min [z-min #f] #:z-max [z-max #f]
         #:width [width (plot-width)]
         #:height [height (plot-height)]
         #:angle [angle (plot3d-angle)]
         #:altitude [altitude (plot3d-altitude)]
         #:title [title (plot-title)]
         #:x-label [x-label (plot-x-label)]
         #:y-label [y-label (plot-y-label)]
         #:z-label [z-label (plot-z-label)]
         #:aspect-multiplier [aspect-multiplier 1]
         #:legend-anchor [legend-anchor (plot-legend-anchor)])
  ;; A solver call commonly follows immediately after showing geometry and
  ;; synchronously blocks its caller.  Give each Plot3D frame an independent
  ;; handler thread so orbit, resize, repaint, and close events remain usable
  ;; throughout that wait.  Preserve the caller's complete Plot parameter set,
  ;; but replace its eventspace when the queued callback installs it.
  (define caller-parameterization (current-parameterization))
  (define eventspace (make-eventspace))
  (define ready (make-channel))
  (parameterize ([current-eventspace eventspace])
    (queue-callback
     (lambda ()
       (with-handlers ([exn:fail? (lambda (failure)
                                    (channel-put ready failure))])
         (call-with-parameterization
          caller-parameterization
          (lambda ()
            (parameterize ([current-eventspace eventspace])
              (show-proportional-plot3d/current-eventspace
               renderer-tree
               #:x-min x-min #:x-max x-max
               #:y-min y-min #:y-max y-max
               #:z-min z-min #:z-max z-max
               #:width width #:height height
               #:angle angle #:altitude altitude
               #:title title
               #:x-label x-label #:y-label y-label #:z-label z-label
               #:aspect-multiplier aspect-multiplier
               #:legend-anchor legend-anchor))))
         (channel-put ready #t)))
     #f))
  (define result (channel-get ready))
  (when (exn:fail? result) (raise result))
  (void))
