#lang racket/base

(require racket/class
         racket/gui/base
         racket/list
         "plot-cursor.rkt")

(provide
 status-canvas%
 make-legend-panel
 set-container-child-visible!)

;; window<%>.show changes visibility but some GUI backends continue reserving
;; the hidden child's minimum size during container layout. Removing the child
;; from the container's active list makes collapsing a legend reclaim its full
;; width; the same window can be reinserted later without rebuilding it.
(define (set-container-child-visible! container child visible?)
  (send container change-children
        (lambda (children)
          (cond
            [visible?
             (if (memq child children)
                 children
                 (append children (list child)))]
            [else (remq child children)]))))

(define (color-value value fallback)
  (cond
    [(is-a? value color%) value]
    [(string? value) (or (send the-color-database find-color value) fallback)]
    [(symbol? value)
     (or (send the-color-database find-color (symbol->string value)) fallback)]
    [(and (list? value) (= (length value) 3) (andmap byte? value))
     (apply make-object color% value)]
    [else fallback]))

(define status-canvas%
  (class canvas%
    (init parent
          [background "white"]
          [foreground "black"]
          [initial-lines '("Left drag: zoom  |  left click: unzoom"
                           "Right drag: inspect values")])
    (define background-color
      (color-value background (make-object color% 255 255 255)))
    (define foreground-color
      (color-value foreground (make-object color% 0 0 0)))
    (define lines initial-lines)

    (define/public (set-content content)
      (set! lines
            (cond
              [(and (list? content) (andmap string? content))
               (take (append content '("" "")) 2)]
              [(string? content) (list content "")]
              [else (list (format "~a" content) "")]))
      (send this refresh))

    (define/override (on-paint)
      (define dc (send this get-dc))
      (define-values (width height) (send dc get-size))
      (send dc set-background background-color)
      (send dc clear)
      (send dc set-text-foreground foreground-color)
      (send dc set-clipping-rect 0 0 width height)
      (for ([line (in-list (take (append lines '("" "")) 2))]
            [y (in-list '(3 23))])
        (send dc draw-text line 6 y)))

    (super-new [parent parent]
               [style '(border)]
               [min-height 45]
               [stretchable-height #f]
               [stretchable-width #t])))

(define swatch-canvas%
  (class canvas%
    (init parent)
    (init-field item)
    (init [background "white"])
    (define background-color
      (color-value background (make-object color% 255 255 255)))
    (define item-color
      (color-value (plot-legend-item-color item)
                   (make-object color% 0 0 0)))
    (define/override (on-paint)
      (define dc (send this get-dc))
      (define-values (width height) (send dc get-size))
      (send dc set-background background-color)
      (send dc clear)
      (case (plot-legend-item-kind item)
        [(box)
         (send dc set-pen item-color 1 'solid)
         (send dc set-brush item-color 'solid)
         (send dc draw-rectangle 4 4 (max 1 (- width 8)) (max 1 (- height 8)))]
        [else
         (send dc set-pen item-color 2 (plot-legend-item-style item))
         (send dc draw-line 2 (quotient height 2)
               (- width 2) (quotient height 2))]))
    (super-new [parent parent]
               [min-width 42]
               [min-height 20]
               [stretchable-width #f]
               [stretchable-height #f])))

(define (make-legend-panel parent items
                           #:background [background "white"]
                           #:foreground [_foreground "black"])
  (define holder
    (new group-box-panel%
         [parent parent]
         [label "Legend"]
         [alignment '(left top)]
         [stretchable-width #f]
         [stretchable-height #t]
         [border 5]
         [spacing 2]))
  (for ([item (in-list items)])
    (define row
      (new horizontal-panel%
           [parent holder]
           [alignment '(left center)]
           [stretchable-width #f]
           [stretchable-height #f]
           [spacing 3]))
    (new swatch-canvas% [parent row] [item item] [background background])
    ;; Use the platform label color here. Unlike the custom-drawn status
    ;; canvas, this panel has the platform's ordinary control background and
    ;; should follow its light/dark theme automatically.
    (new message%
         [parent row]
         [label (format "~a" (plot-legend-item-label item))]
         [stretchable-width #f]))
  holder)
