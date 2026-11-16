#lang racket/base

(provide
 (struct-out simulation-profile)
 draft
 standard
 wire-reference
 derive-simulation-profile)

;; A profile contains numerical-accuracy and solver-stopping policy. Runtime
;; concerns such as artifact retention, progress UI, Octave location, and a
;; wall-clock timeout deliberately remain arguments to `simulate`.
(struct simulation-profile
  (name
   frequency-steps
   cells-per-wavelength
   minimum-dielectric-cells
   minimum-trace-cells
   metal-edge-resolution
   mesh-grading
   padding-wavelengths
   maximum-timesteps
   end-criteria
   wire-segments
   minimum-wire-cells
   wire-halo-radii)
  #:guard
  (lambda (name frequency-steps cells-per-wavelength
                minimum-dielectric-cells minimum-trace-cells
                metal-edge-resolution mesh-grading
                padding-wavelengths maximum-timesteps end-criteria
                wire-segments minimum-wire-cells wire-halo-radii type-name)
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
    (unless (exact-positive-integer? minimum-trace-cells)
      (raise-argument-error
       type-name "exact-positive-integer?" minimum-trace-cells))
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
    (unless (or (not minimum-wire-cells)
                (and (exact-integer? minimum-wire-cells)
                     (>= minimum-wire-cells 2)))
      (raise-argument-error
       type-name "#f or exact-integer? >= 2" minimum-wire-cells))
    (unless (and (finite-positive? wire-halo-radii)
                 (>= wire-halo-radii 1))
      (raise-argument-error
       type-name "finite real >= 1" wire-halo-radii))
    (values name frequency-steps cells-per-wavelength
            minimum-dielectric-cells minimum-trace-cells
            metal-edge-resolution mesh-grading
            padding-wavelengths maximum-timesteps end-criteria wire-segments
            minimum-wire-cells wire-halo-radii))
  #:transparent)

(define draft
  (simulation-profile
   'draft
   101
   20
   4
   3
   #f
   1.4
   0.5
   100000
   1e-4
   24
   #f
   2))

(define standard
  (simulation-profile
   'standard
   101
   30
   6
   5
   #f
   1.4
   0.5
   250000
   1e-5
   24
   #f
   2))

;; An intentionally expensive profile for small, wire-only reference models.
;; It resolves each ordinary wire diameter with six cells and keeps that pitch
;; through a six-radius air halo around centerlines, endpoints, and junctions.
;; Oblique wires can make the Cartesian product of these helpers enormous;
;; callers should dry-run the mesh before starting FDTD.
(define wire-reference
  (simulation-profile
   'wire-reference
   101
   30
   6
   5
   #f
   1.3
   0.5
   250000
   1e-5
   32
   6
   6))

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
         #:minimum-trace-cells
         [minimum-trace-cells
          (simulation-profile-minimum-trace-cells base)]
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
         [wire-segments (simulation-profile-wire-segments base)]
         #:minimum-wire-cells
         [minimum-wire-cells
          (simulation-profile-minimum-wire-cells base)]
         #:wire-halo-radii
         [wire-halo-radii
          (simulation-profile-wire-halo-radii base)])
  (unless (simulation-profile? base)
    (raise-argument-error
     'derive-simulation-profile "simulation-profile?" base))
  (simulation-profile
   name frequency-steps cells-per-wavelength minimum-dielectric-cells
   minimum-trace-cells
   metal-edge-resolution mesh-grading padding-wavelengths
   maximum-timesteps end-criteria wire-segments
   minimum-wire-cells wire-halo-radii))
