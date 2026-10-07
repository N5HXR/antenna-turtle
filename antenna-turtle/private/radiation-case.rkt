#lang racket/base

(provide (struct-out radiation-case))

;; A deliberately small presentation value. Analysis remains represented by
;; nec2c-pattern-grid; this merely gives a grid its comparison-view title.
(struct radiation-case (title grid) #:transparent)
