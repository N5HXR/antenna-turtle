#lang racket/base

(require racket/list
         racket/stxparam
         (for-syntax racket/base
                     syntax/parse))

(provide
 optimizer?
 make-optimizer
 optimizer-track!
 optimizer-best
 optimizer-best-annotation
 optimizer-best-result
 optimizer-list
 optimizer-count
 with-optimizer
 track
 best
 (struct-out optimization-run))

;; An annotation describes how the programmer produced the candidate. The
;; result is the opaque value compared by the optimizer's better? procedure.
(struct optimization-run (annotation result number)
  #:transparent)

;; Runs are accumulated newest-first so tracking remains constant-time. Public
;; list operations restore evaluation order before applying the stable sort.
(struct optimizer (better? runs best-run tracked-count)
  #:mutable
  #:constructor-name make-optimizer-state)

(define (make-optimizer better?)
  (unless (and (procedure? better?)
               (procedure-arity-includes? better? 2))
    (raise-argument-error
     'make-optimizer "procedure accepting two arguments" better?))
  (make-optimizer-state better? '() #f 0))

(define (optimizer-track! tracker annotation result)
  (unless (optimizer? tracker)
    (raise-argument-error 'optimizer-track! "optimizer?" tracker))
  (define number (add1 (optimizer-tracked-count tracker)))
  (define run (optimization-run annotation result number))
  (set-optimizer-runs! tracker (cons run (optimizer-runs tracker)))
  (set-optimizer-tracked-count! tracker number)
  (define previous-best (optimizer-best-run tracker))
  (when (or (not previous-best)
            ((optimizer-better? tracker)
             result
             (optimization-run-result previous-best)))
    (set-optimizer-best-run! tracker run))
  run)

(define (optimizer-best tracker)
  (unless (optimizer? tracker)
    (raise-argument-error 'optimizer-best "optimizer?" tracker))
  (optimizer-best-run tracker))

(define (optimizer-best-annotation tracker)
  (define best (optimizer-best tracker))
  (and best (optimization-run-annotation best)))

(define (optimizer-best-result tracker)
  (define best (optimizer-best tracker))
  (and best (optimization-run-result best)))

(define (optimizer-list tracker)
  (unless (optimizer? tracker)
    (raise-argument-error 'optimizer-list "optimizer?" tracker))
  (define better? (optimizer-better? tracker))
  (sort (reverse (optimizer-runs tracker))
        (lambda (left right)
          (better? (optimization-run-result left)
                   (optimization-run-result right)))))

(define (optimizer-count tracker)
  (unless (optimizer? tracker)
    (raise-argument-error 'optimizer-count "optimizer?" tracker))
  (optimizer-tracked-count tracker))

(define (optimizer-best-select tracker selector)
  (define run (optimizer-best tracker))
  (and run
       (case selector
         [(key annotation) (optimization-run-annotation run)]
         [(result) (optimization-run-result run)]
         [(run) run]
         [(number) (optimization-run-number run)]
         [else
          (raise-argument-error
           'best "(or/c 'key 'annotation 'result 'run 'number)" selector)])))

(define-syntax-parameter track
  (lambda (stx)
    (raise-syntax-error
     'track "may only be used inside with-optimizer" stx)))

(define-syntax-parameter best
  (lambda (stx)
    (raise-syntax-error
     'best "may only be used inside with-optimizer" stx)))

(define-syntax (with-optimizer stx)
  (syntax-parse stx
    [(_ better?:expr body:expr ...+)
     #'(let ([tracker (make-optimizer better?)])
         (syntax-parameterize
             ([track
               (syntax-rules ()
                 [(_ key result)
                  (optimizer-track! tracker key result)])]
              [best
               (syntax-rules ()
                 [(_) (optimizer-best tracker)]
                 [(_ selector) (optimizer-best-select tracker selector)])])
           body ...))]))
