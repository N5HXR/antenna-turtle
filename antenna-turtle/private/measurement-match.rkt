#lang racket/base

(require racket/list
         racket/math
         "measurement-network.rkt")

(provide
 (struct-out multi-match-point)
 (struct-out multi-match-result)
 multi-match
 multi-match-rank
 multi-match<?)

(struct multi-match-point
  (frequency-mhz vswr return-loss-db mismatch-loss-db classification)
  #:transparent)

(struct multi-match-result
  (points
   good-vswr maximum-vswr score
   good-count usable-count outside-count
   worst-vswr mean-vswr mean-mismatch-loss-db)
  #:transparent)

(define (finite-positive-real? value)
  (and (real? value)
       (not (infinite? value))
       (not (nan? value))
       (positive? value)))

(define (mismatch-loss-db vswr)
  (cond
    [(infinite? vswr) +inf.0]
    [else
     (define efficiency (/ (* 4.0 vswr) (sqr (+ vswr 1.0))))
     (* -10.0 (/ (log efficiency) (log 10.0)))]))

(define (arithmetic-mean values)
  (if (ormap infinite? values)
      +inf.0
      (/ (apply + values) (length values))))

(define (point-quality vswr good-vswr maximum-vswr)
  ;; A transparent presentation score with useful landmarks: 100 at 1:1,
  ;; 90 at the good threshold, 20 at the hard threshold, and 0 at twice the
  ;; hard threshold. Ranking decisions use multi-match-rank instead.
  (cond
    [(<= vswr 1) 1.0]
    [(<= vswr good-vswr)
     (- 1.0 (* 0.1 (/ (- vswr 1.0) (- good-vswr 1.0))))]
    [(<= vswr maximum-vswr)
     (- 0.9
        (* 0.7
           (/ (log (/ vswr good-vswr))
              (log (/ maximum-vswr good-vswr)))))]
    [(or (infinite? vswr) (>= vswr (* 2 maximum-vswr))) 0.0]
    [else
     (* 0.2
        (- 1.0
           (/ (log (/ vswr maximum-vswr)) (log 2.0))))]))

(define (multi-match result frequencies
                     #:port [port #f]
                     #:good-vswr [good-vswr 2.0]
                     #:maximum-vswr [maximum-vswr 10.0]
                     #:interpolate? [interpolate? #t])
  (unless (and (list? frequencies) (pair? frequencies)
               (andmap finite-positive-real? frequencies))
    (raise-argument-error
     'multi-match "nonempty list of positive finite frequencies in MHz"
     frequencies))
  (unless (and (finite-positive-real? good-vswr) (> good-vswr 1))
    (raise-argument-error 'multi-match "finite real > 1" good-vswr))
  (unless (and (finite-positive-real? maximum-vswr)
               (> maximum-vswr good-vswr))
    (raise-argument-error
     'multi-match "finite real > #:good-vswr" maximum-vswr))
  (unless (boolean? interpolate?)
    (raise-argument-error 'multi-match "boolean?" interpolate?))
  (define points
    (for/list ([frequency (in-list frequencies)])
      (define vswr
        (vswr-at result frequency
                 #:port port #:interpolate? interpolate?))
      (multi-match-point
       frequency vswr
       (vswr->return-loss vswr)
       (mismatch-loss-db vswr)
       (cond [(<= vswr good-vswr) 'good]
             [(<= vswr maximum-vswr) 'tunable]
             [else 'outside-limit]))))
  (define vswrs (map multi-match-point-vswr points))
  (define losses (map multi-match-point-mismatch-loss-db points))
  (define qualities
    (for/list ([vswr (in-list vswrs)])
      (point-quality vswr good-vswr maximum-vswr)))
  (define good-count (count (lambda (value) (<= value good-vswr)) vswrs))
  (define usable-count (count (lambda (value) (<= value maximum-vswr)) vswrs))
  (multi-match-result
   points good-vswr maximum-vswr
   (* 100.0
      (+ (* 0.7 (/ (apply + qualities) (length qualities)))
         (* 0.3 (apply min qualities))))
   good-count usable-count (- (length points) usable-count)
   (apply max vswrs)
   (arithmetic-mean vswrs)
   (arithmetic-mean losses)))

(define (multi-match-rank result)
  (unless (multi-match-result? result)
    (raise-argument-error 'multi-match-rank "multi-match-result?" result))
  ;; Smaller is better. The tuple exposes the exact optimization priorities
  ;; rather than relying on the intentionally presentational 0--100 score.
  (list
   (multi-match-result-outside-count result)
   (multi-match-result-worst-vswr result)
   (- (multi-match-result-good-count result))
   (multi-match-result-mean-mismatch-loss-db result)
   (multi-match-result-mean-vswr result)))

(define (rank<? left right)
  (cond
    [(null? left) #f]
    [(< (car left) (car right)) #t]
    [(> (car left) (car right)) #f]
    [else (rank<? (cdr left) (cdr right))]))

(define (multi-match<? left right)
  (rank<? (multi-match-rank left) (multi-match-rank right)))
