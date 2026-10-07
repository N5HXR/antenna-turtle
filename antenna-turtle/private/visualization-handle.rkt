#lang racket/base

(provide visualization-handle?
         visualization-update!
         visualization-show!
         visualization-close!
         visualization-open?
         make-visualization-handle)

;; GUI implementations retain their own widgets and eventspace. Keeping those
;; details behind callbacks gives Antenna Turtle one small public protocol that
;; can later be shared by Plot-backed viewers without exposing Racket GUI
;; objects as part of the language API.
(struct visualization-handle (update show close open?)
  #:constructor-name make-visualization-handle)

(define (check-handle who handle)
  (unless (visualization-handle? handle)
    (raise-argument-error who "visualization-handle?" handle)))

(define (visualization-update! handle data)
  (check-handle 'visualization-update! handle)
  ((visualization-handle-update handle) data))

(define (visualization-show! handle)
  (check-handle 'visualization-show! handle)
  ((visualization-handle-show handle)))

(define (visualization-close! handle)
  (check-handle 'visualization-close! handle)
  ((visualization-handle-close handle)))

(define (visualization-open? handle)
  (check-handle 'visualization-open? handle)
  ((visualization-handle-open? handle)))
