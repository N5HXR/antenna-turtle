#lang racket

(require rackunit
         "../antenna-turtle/main.rkt")

(test-case "built-in simulation profiles expose the documented policies"
  (check-equal? (simulation-profile-name draft) 'draft)
  (check-equal? (simulation-profile-cells-per-wavelength draft) 20)
  (check-equal? (simulation-profile-minimum-dielectric-cells draft) 4)
  (check-equal? (simulation-profile-maximum-timesteps draft) 100000)
  (check-equal? (simulation-profile-end-criteria draft) 1e-4)

  (check-equal? (simulation-profile-name standard) 'standard)
  (check-equal? (simulation-profile-cells-per-wavelength standard) 30)
  (check-equal? (simulation-profile-minimum-dielectric-cells standard) 6)
  (check-equal? (simulation-profile-maximum-timesteps standard) 250000)
  (check-equal? (simulation-profile-end-criteria standard) 1e-5))

(test-case "derived profiles replace only explicit fields"
  (define convergence
    (derive-simulation-profile
     standard
     #:name 'convergence
     #:cells-per-wavelength 40
     #:minimum-dielectric-cells 8
     #:maximum-timesteps 400000))
  (check-equal? (simulation-profile-name convergence) 'convergence)
  (check-equal? (simulation-profile-cells-per-wavelength convergence) 40)
  (check-equal? (simulation-profile-minimum-dielectric-cells convergence) 8)
  (check-equal? (simulation-profile-maximum-timesteps convergence) 400000)
  (check-equal? (simulation-profile-end-criteria convergence)
                (simulation-profile-end-criteria standard))
  (check-equal? (simulation-profile-wire-segments convergence)
                (simulation-profile-wire-segments standard))
  (check-exn
   exn:fail:contract?
   (lambda ()
     (derive-simulation-profile standard #:cells-per-wavelength 0))))
