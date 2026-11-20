#lang racket/base

(provide rf-phase-degrees-per-second
         normalize-rf-phase
         advance-rf-phase
         make-rf-phase-clock
         (struct-out rf-phase-clock)
         rf-phase-clock-start!
         rf-phase-clock-stop!
         rf-phase-clock-set-phase!
         rf-phase-clock-set-speed!
         rf-phase-clock-tick!)

(define rf-phase-degrees-per-second 180.0)

(define (normalize-rf-phase degrees)
  (unless (real? degrees)
    (raise-argument-error 'normalize-rf-phase "real?" degrees))
  (- degrees (* 360.0 (floor (/ degrees 360.0)))))

(define (advance-rf-phase phase elapsed-seconds speed)
  (unless (real? phase)
    (raise-argument-error 'advance-rf-phase "real?" phase))
  (unless (and (real? elapsed-seconds) (>= elapsed-seconds 0))
    (raise-argument-error
     'advance-rf-phase "nonnegative-real?" elapsed-seconds))
  (unless (and (real? speed) (positive? speed))
    (raise-argument-error 'advance-rf-phase "positive-real?" speed))
  (normalize-rf-phase
   (+ phase (* rf-phase-degrees-per-second elapsed-seconds speed))))

;; The clock's running state represents the user's play/pause choice. A view
;; may stop its render timer while leaving this state true (for example, a
;; static vector view). Calling start! when rendering resumes intentionally
;; resets last-tick so hidden or static time is never accumulated as a jump.
(struct rf-phase-clock (phase speed running? last-tick) #:mutable #:transparent)

(define (make-rf-phase-clock #:phase [phase 0.0]
                             #:speed [speed 1.0]
                             #:running? [running? #t]
                             #:now [now (current-inexact-milliseconds)])
  (unless (boolean? running?)
    (raise-argument-error 'make-rf-phase-clock "boolean?" running?))
  (unless (real? now)
    (raise-argument-error 'make-rf-phase-clock "real?" now))
  (rf-phase-clock (normalize-rf-phase phase)
                  (begin
                    (unless (and (real? speed) (positive? speed))
                      (raise-argument-error
                       'make-rf-phase-clock "positive-real?" speed))
                    speed)
                  running?
                  now))

(define (rf-phase-clock-start! clock [now (current-inexact-milliseconds)])
  (unless (rf-phase-clock? clock)
    (raise-argument-error 'rf-phase-clock-start! "rf-phase-clock?" clock))
  (unless (real? now)
    (raise-argument-error 'rf-phase-clock-start! "real?" now))
  (set-rf-phase-clock-running?! clock #t)
  (set-rf-phase-clock-last-tick! clock now)
  (rf-phase-clock-phase clock))
(define (rf-phase-clock-stop! clock)
  (unless (rf-phase-clock? clock)
    (raise-argument-error 'rf-phase-clock-stop! "rf-phase-clock?" clock))
  (set-rf-phase-clock-running?! clock #f)
  (rf-phase-clock-phase clock))

(define (rf-phase-clock-set-phase! clock phase)
  (unless (rf-phase-clock? clock)
    (raise-argument-error 'rf-phase-clock-set-phase! "rf-phase-clock?" clock))
  (set-rf-phase-clock-phase! clock (normalize-rf-phase phase))
  (rf-phase-clock-phase clock))

(define (rf-phase-clock-set-speed! clock speed)
  (unless (rf-phase-clock? clock)
    (raise-argument-error 'rf-phase-clock-set-speed! "rf-phase-clock?" clock))
  (unless (and (real? speed) (positive? speed))
    (raise-argument-error 'rf-phase-clock-set-speed! "positive-real?" speed))
  (set-rf-phase-clock-speed! clock speed)
  speed)

(define (rf-phase-clock-tick! clock [now (current-inexact-milliseconds)])
  (unless (rf-phase-clock? clock)
    (raise-argument-error 'rf-phase-clock-tick! "rf-phase-clock?" clock))
  (unless (real? now)
    (raise-argument-error 'rf-phase-clock-tick! "real?" now))
  (when (rf-phase-clock-running? clock)
    (define elapsed
      (max 0.0 (/ (- now (rf-phase-clock-last-tick clock)) 1000.0)))
    (set-rf-phase-clock-phase!
     clock
     (advance-rf-phase (rf-phase-clock-phase clock)
                       elapsed
                       (rf-phase-clock-speed clock))))
  (set-rf-phase-clock-last-tick! clock now)
  (rf-phase-clock-phase clock))
