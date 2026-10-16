#lang info

;; The collection setup walker treats `private` as a subcollection, so the
;; omission policy must live here rather than only in the parent collection's
;; info file. These modules are compiled transitively from main.rkt when its
;; Manifold probe succeeds.
(define compile-omit-paths
  '("mesh-constraint.rkt"
    "solid-core.rkt"
    "solid-csg.rkt"
    "solid-csg-dsl.rkt"
    "solid-dsl.rkt"
    "solid-placement.rkt"
    "solid-primitives.rkt"
    "solid-trace.rkt"
    "solid-trace-dsl.rkt"
    "solid-view.rkt"
    "stl-import.rkt"
    "wire-solid.rkt"
    "openems.rkt"
    "openems-power.rkt"
    "simulation-dsl.rkt"
    "measurement-network.rkt"
    "measurement.rkt"
    "nec2c-view.rkt"))
