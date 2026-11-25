#lang racket

(require rackunit
         "../antenna-turtle/main.rkt")

(test-case "optimizer tracks opaque results and annotations"
  (define tracker (make-optimizer <))
  (define first-run (optimizer-track! tracker '(length 1.0) 5))
  (optimizer-track! tracker (hasheq 'length 0.9) 2)
  (optimizer-track! tracker 'experimental 3)
  (optimizer-track! tracker 'last 8)
  (check-equal? (optimizer-count tracker) 4)
  (check-equal? (optimization-run-number first-run) 1)
  (check-equal? (optimization-run-result (optimizer-best tracker)) 2)
  (check-equal? (optimizer-best-annotation tracker) (hasheq 'length 0.9))
  (check-equal? (optimizer-best-result tracker) 2)
  (check-equal? (map optimization-run-result (optimizer-list tracker))
                '(2 3 5 8)))

(test-case "optimizer preserves evaluation order for tied results"
  (define tracker (make-optimizer <))
  (optimizer-track! tracker 'first 2)
  (optimizer-track! tracker 'second 2)
  (optimizer-track! tracker 'third 2)
  (check-equal? (map optimization-run-annotation (optimizer-list tracker))
                '(first second third))
  (check-equal? (optimization-run-annotation (optimizer-best tracker))
                'first))

(test-case "a comparator can place disqualified results last"
  (define (qualified? result) (positive? result))
  (define (better? left right)
    (cond
      [(not (qualified? left)) #f]
      [(not (qualified? right)) #t]
      [else (< left right)]))
  (define tracker (make-optimizer better?))
  (for ([result (in-list '(-1 4 2 0 -2 3))])
    (optimizer-track! tracker result result))
  (check-equal? (map optimization-run-result (optimizer-list tracker))
                '(2 3 4 -1 0 -2))
  (check-equal? (optimization-run-result (optimizer-best tracker)) 2))

(test-case "an empty optimizer has no best run"
  (define tracker (make-optimizer <))
  (check-false (optimizer-best tracker))
  (check-false (optimizer-best-annotation tracker))
  (check-false (optimizer-best-result tracker))
  (check-equal? (optimizer-list tracker) '())
  (check-equal? (optimizer-count tracker) 0)
  (check-exn exn:fail:contract? (lambda () (make-optimizer add1))))

(test-case "with-optimizer provides scoped tracking forms"
  (define winning-key
    (with-optimizer <
      ;; Internal definitions remain ordinary lexical definitions.
      (define (measure candidate) (abs candidate))
      (for ([candidate (in-list '(-4 3 -1 2))])
        (track `(candidate ,candidate) (measure candidate)))
      (check-equal? (best 'result) 1)
      (check-equal? (best 'number) 3)
      (check-true (optimization-run? (best 'run)))
      (check-eq? (best) (best 'run))
      (best 'key)))
  (check-equal? winning-key '(candidate -1)))

(test-case "with-optimizer handles an empty search"
  (with-optimizer <
    (check-false (best))
    (check-false (best 'key))
    (check-false (best 'result))))

(test-case "track and best reject use outside with-optimizer"
  (check-exn exn:fail:syntax? (lambda () (expand #'(track 'candidate 1))))
  (check-exn exn:fail:syntax? (lambda () (expand #'(best 'key)))))
