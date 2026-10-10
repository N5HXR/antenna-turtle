#lang racket/base

(provide
 (struct-out simulation-profile)
 draft
 standard
 derive-simulation-profile)

;; A profile contains numerical-accuracy and solver-stopping policy. Runtime
;; concerns such as artifact retention, progress UI, Octave location, and a
;; wall-clock timeout deliberately remain arguments to `simulate`.
(struct simulation-profile
  (name
   frequency-steps
   cells-per-wavelength
   minimum-dielectric-cells
   metal-edge-resolution
   mesh-grading
   padding-wavelengths
   maximum-timesteps
   end-criteria
   wire-segments)
  #:guard
  (lambda (name frequency-steps cells-per-wavelength
                minimum-dielectric-cells metal-edge-resolution mesh-grading
                padding-wavelengths maximum-timesteps end-criteria
                wire-segments type-name)
    (define (finite-positive? value)
      (and (real? value) (rational? value) (positive? value)))
    (unless (or (symbol? name) (string? name))
      (raise-argument-error type-name "(or/c symbol? string?)" name))
    (unless (and (exact-integer? frequency-steps) (>= frequency-steps 2))
      (raise-argument-error type-name "exact-integer? >= 2" frequency-steps))
    (unless (finite-positive? cells-per-wavelength)
      (raise-argument-error type-name "positive finite real" cells-per-wavelength))
    (unless (exact-positive-integer? minimum-dielectric-cells)
      (raise-argument-error
       type-name "exact-positive-integer?" minimum-dielectric-cells))
    (unless (or (not metal-edge-resolution)
                (finite-positive? metal-edge-resolution))
      (raise-argument-error
       type-name "#f or positive finite real" metal-edge-resolution))
    (unless (and (finite-positive? mesh-grading) (> mesh-grading 1))
      (raise-argument-error type-name "finite real > 1" mesh-grading))
    (unless (finite-positive? padding-wavelengths)
      (raise-argument-error type-name "positive finite real" padding-wavelengths))
    (unless (exact-positive-integer? maximum-timesteps)
      (raise-argument-error
       type-name "exact-positive-integer?" maximum-timesteps))
    (unless (and (finite-positive? end-criteria) (< end-criteria 1))
      (raise-argument-error type-name "finite real between 0 and 1" end-criteria))
    (unless (and (exact-integer? wire-segments) (>= wire-segments 3))
      (raise-argument-error type-name "exact-integer? >= 3" wire-segments))
    (values name frequency-steps cells-per-wavelength
            minimum-dielectric-cells metal-edge-resolution mesh-grading
            padding-wavelengths maximum-timesteps end-criteria wire-segments))
  #:transparent)

(define draft
  (simulation-profile
   'draft
   101
   20
   4
   #f
   1.4
   0.5
   100000
   1e-4
   24))

(define standard
  (simulation-profile
   'standard
   101
   30
   6
   #f
   1.4
   0.5
   250000
   1e-5
   24))

(define (derive-simulation-profile
         base
         #:name [name (simulation-profile-name base)]
         #:frequency-steps
         [frequency-steps (simulation-profile-frequency-steps base)]
         #:cells-per-wavelength
         [cells-per-wavelength
          (simulation-profile-cells-per-wavelength base)]
         #:minimum-dielectric-cells
         [minimum-dielectric-cells
          (simulation-profile-minimum-dielectric-cells base)]
         #:metal-edge-resolution
         [metal-edge-resolution
          (simulation-profile-metal-edge-resolution base)]
         #:mesh-grading
         [mesh-grading (simulation-profile-mesh-grading base)]
         #:padding-wavelengths
         [padding-wavelengths
          (simulation-profile-padding-wavelengths base)]
         #:maximum-timesteps
         [maximum-timesteps
          (simulation-profile-maximum-timesteps base)]
         #:end-criteria
         [end-criteria (simulation-profile-end-criteria base)]
         #:wire-segments
         [wire-segments (simulation-profile-wire-segments base)])
  (unless (simulation-profile? base)
    (raise-argument-error
     'derive-simulation-profile "simulation-profile?" base))
  (simulation-profile
   name frequency-steps cells-per-wavelength minimum-dielectric-cells
   metal-edge-resolution mesh-grading padding-wavelengths
   maximum-timesteps end-criteria wire-segments))
