#lang racket/base

(require racket/class
         racket/list
         racket/match
         plot/no-gui
         "plot-cursor.rkt")

(provide amateur-band-renderers
         visible-amateur-band-segments
         (struct-out amateur-band-segment))

;; United States amateur allocations, in MHz, from 2200 meters through
;; 3 centimeters.  Bands with discontinuous allocations deliberately have
;; multiple segments.  In particular, 60 meters consists of five 2.8 kHz
;; channels rather than one continuous band.
(struct amateur-band-segment (name low-mhz high-mhz) #:transparent)

(define us-amateur-band-segments
  (list
   (amateur-band-segment "2200m" 0.1357 0.1378)
   (amateur-band-segment "630m" 0.472 0.479)
   (amateur-band-segment "160m" 1.8 2.0)
   (amateur-band-segment "80m" 3.5 4.0)
   (amateur-band-segment "60m" 5.3306 5.3334)
   (amateur-band-segment "60m" 5.3466 5.3494)
   (amateur-band-segment "60m" 5.3571 5.3599)
   (amateur-band-segment "60m" 5.3716 5.3744)
   (amateur-band-segment "60m" 5.4036 5.4064)
   (amateur-band-segment "40m" 7.0 7.3)
   (amateur-band-segment "30m" 10.1 10.15)
   (amateur-band-segment "20m" 14.0 14.35)
   (amateur-band-segment "17m" 18.068 18.168)
   (amateur-band-segment "15m" 21.0 21.45)
   (amateur-band-segment "12m" 24.89 24.99)
   (amateur-band-segment "10m" 28.0 29.7)
   (amateur-band-segment "6m" 50.0 54.0)
   (amateur-band-segment "2m" 144.0 148.0)
   (amateur-band-segment "1.25m" 219.0 220.0)
   (amateur-band-segment "1.25m" 222.0 225.0)
   (amateur-band-segment "70cm" 420.0 450.0)
   (amateur-band-segment "33cm" 902.0 928.0)
   (amateur-band-segment "23cm" 1240.0 1300.0)
   (amateur-band-segment "13cm" 2300.0 2310.0)
   (amateur-band-segment "13cm" 2390.0 2450.0)
   (amateur-band-segment "9cm" 3300.0 3450.0)
   (amateur-band-segment "5cm" 5650.0 5925.0)
   (amateur-band-segment "3cm" 10000.0 10500.0)))

(define (visible-amateur-band-segments x-min x-max)
  (for/list ([segment (in-list us-amateur-band-segments)]
             #:when
             (and (< (amateur-band-segment-low-mhz segment) x-max)
                  (> (amateur-band-segment-high-mhz segment) x-min)))
    segment))

(define (series-frequency-range series-list)
  (define frequencies
    (for*/list ([series (in-list series-list)]
                [point (in-list (cursor-series-points series))]
                #:when (and (> (vector-length point) 0)
                            (rational? (vector-ref point 0))))
      (vector-ref point 0)))
  (and (pair? frequencies)
       (cons (apply min frequencies) (apply max frequencies))))

(define band-fill-color '(65 145 205))

(define (band-label-renderer segments)
  ;; Labels are opportunistic: draw one only when its visible strip is wide
  ;; enough in screen space.  Very narrow allocations still retain their
  ;; shading without becoming an unreadable pile of text.
  (renderer2d
   #f #f #f #f
   (lambda (area)
     (match-define
       (vector (ivl x-min x-max) (ivl _ y-max))
       (send area get-bounds-rect))
     (send area put-alpha 0.62)
     (send area put-font-size 7)
     (send area put-text-foreground '(55 85 105))
     (for ([segment (in-list segments)])
       (define low (max x-min (amateur-band-segment-low-mhz segment)))
       (define high (min x-max (amateur-band-segment-high-mhz segment)))
       (define left-pixel (vector-ref (send area plot->dc (vector low y-max)) 0))
       (define right-pixel (vector-ref (send area plot->dc (vector high y-max)) 0))
       (when (>= (abs (- right-pixel left-pixel)) 17)
         (send area put-text
               (amateur-band-segment-name segment)
               (vector (/ (+ low high) 2) y-max)
               'top 0 2 #f))))))

(define (amateur-band-renderers series-list)
  (define range (series-frequency-range series-list))
  (cond
    [(not range) '()]
    [else
     (define x-min (car range))
     (define x-max (cdr range))
     (define segments (visible-amateur-band-segments x-min x-max))
     (if (null? segments)
         '()
         (list
          (rectangles
           (for/list ([segment (in-list segments)])
             (vector
              (ivl (max x-min (amateur-band-segment-low-mhz segment))
                   (min x-max (amateur-band-segment-high-mhz segment)))
              (ivl -inf.0 +inf.0)))
           #:color band-fill-color
           #:line-width 0
           #:alpha 0.12)
          (band-label-renderer segments)))]))
