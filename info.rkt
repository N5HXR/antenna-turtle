#lang info

(define collection 'multi)
(define setup-collects '("antenna-turtle"))
(define deps '("base" "gui-lib" "json-lib" "k-infix"
               "pict3d" "plot-lib" "plot-gui-lib"))
(define build-deps '("rackunit-lib"))
(define pkg-desc "A turtle-graphics DSL for antenna wire geometry")
(define version "0.5.0")
(define pkg-authors '("Josh Stone, N5HXR"))
(define license 'MIT)
