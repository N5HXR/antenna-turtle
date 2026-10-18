#lang info

;; This directory contains MMANA-GAL antenna-model data. One legacy model has
;; a `.rkt` suffix even though its contents are not Racket source, so keep the
;; setup compiler from treating it as a module when the repository is linked
;; as a multi-collection package.
(define compile-omit-paths '("yagi.rkt"))
