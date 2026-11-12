#lang racket/base

(require racket/format
         racket/list
         racket/math
         racket/match
         racket/runtime-path
         racket/string
         "core.rkt"
         "measurement-network.rkt"
         "measurement-radiation.rkt"
         "nec2c.rkt")

(provide
 pattern-power-gain-integral
 pattern-air-radiation-efficiency
 reflection-mismatch-efficiency
 (struct-out power-metrics)
 analyze-power
 radiation-efficiency
 air-radiation-efficiency
 mismatch-efficiency
 realized-efficiency
 power-loss-breakdown
 format-power-report
 power-report)

;; The efficiency values are ratios in [nominally] 0..1, rather than
;; percentages.  Values are deliberately not clamped: a coarse angular grid
;; or a solver power-balance problem should remain visible to callers.
(struct power-metrics
  (backend frequency-mhz excitation
   incident-power-w reflected-power-w accepted-power-w
   air-radiated-power-w delivered-power-w
   structure-loss-w network-loss-w dielectric-loss-w lumped-loss-w
   residual-loss-w residual-label
   radiation-efficiency mismatch-efficiency realized-efficiency
   gain-integral-sr sampled-solid-angle-sr angular-resolution-deg notes)
  #:transparent)

(define-runtime-path openems-power-module "openems-power.rkt")

(define (db->power value)
  (cond
    [(eqv? value -inf.0) 0.0]
    [(and (real? value) (not (nan? value))) (expt 10.0 (/ value 10.0))]
    [else
     (raise-argument-error
      'pattern-power-gain-integral "a real, non-NaN gain in dB" value)]))

(define (angle-key theta phi)
  ;; NEC text output is decimal while the requested grid may contain exact
  ;; rationals. Quantizing well below any useful angular resolution makes the
  ;; lookup insensitive to that representation boundary.
  (cons (inexact->exact (round (* 1e8 (exact->inexact theta))))
        (inexact->exact
         (round (* 1e8 (modulo (exact->inexact phi) 360.0))))))

(define (strictly-increasing? values)
  (for/and ([left (in-list values)] [right (in-list (rest values))])
    (< left right)))

(define (approximately= local-left local-right [epsilon 1e-7])
  (<= (abs (- local-left local-right))
      (* epsilon (max 1.0 (abs local-left) (abs local-right)))))

(define (uniform-step who values label)
  (unless (and (list? values) (>= (length values) 2)
               (andmap real? values) (strictly-increasing? values))
    (raise-arguments-error
     who "expected at least two strictly increasing angular samples"
     label values))
  (define step (- (second values) (first values)))
  (unless (for/and ([left (in-list values)] [right (in-list (rest values))])
            (approximately= (- right left) step))
    (raise-arguments-error who "angular samples are not uniformly spaced"
                           label values))
  (exact->inexact step))

(define (pattern-frequency pattern)
  (define samples (nec2c-pattern-grid-samples pattern))
  (and (pair? samples)
       (nec2c-pattern-sample-frequency-mhz (first samples))))

(define (pattern-grid-info who pattern)
  (unless (nec2c-pattern-grid? pattern)
    (raise-argument-error who "nec2c-pattern-grid?" pattern))
  (define thetas (nec2c-pattern-grid-theta-values pattern))
  (define phis (nec2c-pattern-grid-phi-values pattern))
  (define theta-step (uniform-step who thetas "theta values"))
  (define phi-step (uniform-step who phis "phi values"))
  (unless (approximately= (first thetas) 0)
    (raise-arguments-error who "theta coverage must begin at zero degrees"
                           "theta values" thetas))
  (unless (or (approximately= (last thetas) 90)
              (approximately= (last thetas) 180))
    (raise-arguments-error
     who "theta coverage must end at 90 or 180 degrees"
     "theta values" thetas))
  (unless (and (approximately= (first phis) 0)
               (approximately= (* phi-step (length phis)) 360))
    (raise-arguments-error
     who "phi samples must cover one complete periodic revolution"
     "phi values" phis))
  (values thetas phis theta-step phi-step))

(define (sample-index who pattern)
  (for/fold ([index (hash)])
            ([sample (in-list (nec2c-pattern-grid-samples pattern))])
    (define key
      (angle-key (nec2c-pattern-sample-theta-deg sample)
                 (nec2c-pattern-sample-phi-deg sample)))
    (when (hash-has-key? index key)
      (raise-arguments-error who "pattern contains a duplicate angular sample"
                             "theta/phi" key))
    (hash-set index key sample)))

(define (sample-gain who index theta phi)
  (define sample (hash-ref index (angle-key theta phi) #f))
  (unless sample
    (raise-arguments-error who "pattern is missing an angular sample"
                           "theta (degrees)" theta
                           "phi (degrees)" phi))
  (db->power (nec2c-pattern-sample-total-gain-db sample)))

(define (directivity-pattern? pattern)
  (define metadata (nec2c-pattern-grid-run pattern))
  (and (hash? metadata)
       (eq? (hash-ref metadata 'backend #f) 'openems)))

(define (pattern-power-gain-integral pattern)
  (define who 'pattern-power-gain-integral)
  (when (and (nec2c-pattern-grid? pattern) (directivity-pattern? pattern))
    (raise-arguments-error
     who
     (string-append
      "OpenEMS pattern grids contain directivity, not accepted-power gain; "
      "use (power-budget result) and analyze that budget instead")
     "pattern backend" 'openems))
  (define-values (thetas phis _theta-step phi-step)
    (pattern-grid-info who pattern))
  (define index (sample-index who pattern))
  (define phi-width (degrees->radians phi-step))
  ;; Integrate each spherical cell using its exact solid angle and the mean
  ;; linear power gain at its four corners. Phi wraps periodically.
  (for*/sum ([(theta0 theta1)
              (in-parallel (in-list (drop-right thetas 1))
                           (in-list (rest thetas)))]
             [phi0 (in-list phis)])
    (define phi1 (modulo (+ phi0 phi-step) 360.0))
    (define solid-angle
      (* phi-width
         (- (cos (degrees->radians theta0))
            (cos (degrees->radians theta1)))))
    (define mean-gain
      (/ (+ (sample-gain who index theta0 phi0)
            (sample-gain who index theta0 phi1)
            (sample-gain who index theta1 phi0)
            (sample-gain who index theta1 phi1))
         4.0))
    (* solid-angle mean-gain)))

(define (pattern-solid-angle pattern)
  (define-values (thetas _phis _theta-step _phi-step)
    (pattern-grid-info 'pattern-solid-angle pattern))
  (* 2.0 pi
     (- (cos (degrees->radians (first thetas)))
        (cos (degrees->radians (last thetas))))))

(define (pattern-air-radiation-efficiency pattern)
  (/ (pattern-power-gain-integral pattern) (* 4.0 pi)))

(define (reflection-mismatch-efficiency reflection-coefficient)
  (unless (number? reflection-coefficient)
    (raise-argument-error
     'reflection-mismatch-efficiency "number?" reflection-coefficient))
  (- 1.0 (sqr (magnitude reflection-coefficient))))

(define (safe-product . values)
  (and (andmap real? values) (apply * values)))

(define (nonnegative-roundoff value reference)
  (if (and (real? value) (negative? value)
           (<= (abs value) (* 1e-8 (max 1.0 (abs reference)))))
      0.0
      value))

(define (single-feed-reflection diagnostics reference-impedance)
  (define feeds (nec2c-diagnostics-feedpoints diagnostics))
  (and (= (length feeds) 1)
       (impedance->reflection-coefficient
        (nec2c-feedpoint-sample-impedance (first feeds))
        reference-impedance)))

(define (nec-pattern->metrics pattern reference-impedance)
  (when (directivity-pattern? pattern)
    (raise-arguments-error
     'analyze-power
     (string-append
      "OpenEMS pattern grids contain directivity, not accepted-power gain; "
      "pass (power-budget result) instead")
     "pattern backend" 'openems))
  (define diagnostics (nec2c-pattern-grid-diagnostics pattern))
  (define budget
    (and (nec2c-diagnostics? diagnostics)
         (nec2c-diagnostics-power-budget diagnostics)))
  (define accepted
    (and (nec2c-power-budget? budget)
         (nec2c-power-budget-input-power budget)))
  (define radiation-eff (pattern-air-radiation-efficiency pattern))
  (define air-radiated (and accepted (* accepted radiation-eff)))
  (define reflection
    (and (nec2c-diagnostics? diagnostics)
         (single-feed-reflection diagnostics reference-impedance)))
  (define mismatch-eff
    (and reflection (reflection-mismatch-efficiency reflection)))
  (define incident
    (and accepted mismatch-eff (positive? mismatch-eff)
         (/ accepted mismatch-eff)))
  (define reflected (and incident (- incident accepted)))
  (define structure
    (and (nec2c-power-budget? budget)
         (nec2c-power-budget-structure-loss budget)))
  (define network
    (and (nec2c-power-budget? budget)
         (nec2c-power-budget-network-loss budget)))
  (define residual
    (and accepted air-radiated structure network
         (nonnegative-roundoff
          (- accepted air-radiated structure network) accepted)))
  (define sampled-solid-angle (pattern-solid-angle pattern))
  (define grounded-pattern?
    (approximately= sampled-solid-angle (* 2.0 pi)))
  (power-metrics
   'nec2c (or (pattern-frequency pattern)
              (and (nec2c-diagnostics? diagnostics)
                   (nec2c-diagnostics-frequency-mhz diagnostics)))
   (and (nec2c-diagnostics? diagnostics)
        (= (length (nec2c-diagnostics-feedpoints diagnostics)) 1)
        (nec2c-feedpoint-sample-feed-name
         (first (nec2c-diagnostics-feedpoints diagnostics))))
   incident reflected accepted air-radiated #f
   structure network #f #f residual
   (if grounded-pattern? 'ground-or-unaccounted 'unaccounted)
   radiation-eff mismatch-eff (and mismatch-eff (* radiation-eff mismatch-eff))
   (pattern-power-gain-integral pattern) sampled-solid-angle
   (pattern-angular-resolution pattern)
   (append
    (if budget '()
        '("NEC did not return an accepted-power budget; absolute watts are unavailable."))
    (if reflection '()
        '("Mismatch and realized efficiency require exactly one retained feedpoint."))
    (list
     "Air-radiated power is integrated from absolute power gain."
     (if grounded-pattern?
         "Ground loss is the accepted-power residual and includes numerical integration error."
         "The accepted-power residual is numerical integration and power-balance error.")))))

;; OpenEMS is an optional backend. Dynamic lookup keeps the wire-only language
;; loadable on installations without Manifold or OpenEMS.
(define (openems-api)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (for/hash ([name (in-list
                      '(openems-power-budget?
                        openems-power-budget-frequency-mhz
                        openems-power-budget-excitation-port
                        openems-power-budget-incident-power-w
                        openems-power-budget-reflected-power-w
                        openems-power-budget-accepted-power-w
                        openems-power-budget-delivered-power-w
                        openems-power-budget-radiated-power-w
                        openems-power-budget-dielectric-power-w
                        openems-power-budget-lumped-power-w
                        openems-power-budget-conductor-and-unaccounted-power-w))])
      (values name (dynamic-require openems-power-module name)))))

(define (openems-budget->metrics budget api)
  (define (ref name) ((hash-ref api name) budget))
  (define incident (ref 'openems-power-budget-incident-power-w))
  (define accepted (ref 'openems-power-budget-accepted-power-w))
  (define radiated (ref 'openems-power-budget-radiated-power-w))
  (define radiation-eff (and (not (zero? accepted)) (/ radiated accepted)))
  (define mismatch-eff (and (not (zero? incident)) (/ accepted incident)))
  (power-metrics
   'openems
   (ref 'openems-power-budget-frequency-mhz)
   (ref 'openems-power-budget-excitation-port)
   incident
   (ref 'openems-power-budget-reflected-power-w)
   accepted radiated
   (ref 'openems-power-budget-delivered-power-w)
   #f #f
   (ref 'openems-power-budget-dielectric-power-w)
   (ref 'openems-power-budget-lumped-power-w)
   (ref 'openems-power-budget-conductor-and-unaccounted-power-w)
   'conductor-or-unaccounted
   radiation-eff mismatch-eff (safe-product radiation-eff mismatch-eff)
   #f #f #f
   '("OpenEMS radiated power is obtained from its NF2FF power integration."
     "The residual includes conducting-sheet loss and numerical closure error.")))

(define (analyze-power source #:reference-impedance
                       [reference-impedance (model-impedance)])
  (cond
    [(power-metrics? source) source]
    [(nec2c-pattern-grid? source)
     (nec-pattern->metrics source reference-impedance)]
    [else
     (define api (openems-api))
     (if (and api ((hash-ref api 'openems-power-budget?) source))
         (openems-budget->metrics source api)
         (raise-argument-error
          'analyze-power
          "(or/c power-metrics? nec2c-pattern-grid? openems-power-budget?)"
          source))]))

(define (as-metrics _who source)
  (analyze-power source))

(define (radiation-efficiency source)
  (power-metrics-radiation-efficiency (as-metrics 'radiation-efficiency source)))

(define air-radiation-efficiency radiation-efficiency)

(define (mismatch-efficiency source)
  (power-metrics-mismatch-efficiency (as-metrics 'mismatch-efficiency source)))

(define (realized-efficiency source)
  (power-metrics-realized-efficiency (as-metrics 'realized-efficiency source)))

(define (power-loss-breakdown source)
  (define metrics (as-metrics 'power-loss-breakdown source))
  (for/hash ([entry
              (in-list
               (list (cons 'structure (power-metrics-structure-loss-w metrics))
                     (cons 'network (power-metrics-network-loss-w metrics))
                     (cons 'dielectric (power-metrics-dielectric-loss-w metrics))
                     (cons 'lumped (power-metrics-lumped-loss-w metrics))
                     (cons (power-metrics-residual-label metrics)
                           (power-metrics-residual-loss-w metrics))))]
             #:when (real? (cdr entry)))
    (values (car entry) (cdr entry))))

(define (format-real value [digits 6])
  (if (real? value)
      (~r value #:notation 'exponential #:precision digits)
      "—"))

(define (format-percent value)
  (if (real? value)
      (format "~a%" (~r (* 100.0 value) #:precision '(= 2)))
      "—"))

(define (format-db-ratio value)
  (cond
    [(not (real? value)) "—"]
    [(positive? value) (format "~a dB" (~r (* 10.0 (/ (log value) (log 10.0)))
                                           #:precision '(= 2)))]
    [(zero? value) "-inf dB"]
    [else "n/a"]))

(define (power-row label power reference)
  (format "~a ~a ~a ~a"
          (~a label #:min-width 30 #:align 'left)
          (~a (if (real? power) (format "~a W" (format-real power)) "—")
              #:min-width 20 #:align 'right)
          (~a (if (and (real? power) (real? reference) (not (zero? reference)))
                  (format-percent (/ power reference)) "—")
              #:min-width 11 #:align 'right)
          (~a (if (and (real? power) (real? reference) (not (zero? reference)))
                  (format-db-ratio (/ power reference)) "—")
              #:min-width 11 #:align 'right)))

(define (format-power-report source #:reference-impedance
                             [reference-impedance (model-impedance)])
  (define metrics (analyze-power source #:reference-impedance reference-impedance))
  (define accepted (power-metrics-accepted-power-w metrics))
  (define table-reference
    (or (and (real? (power-metrics-incident-power-w metrics))
             (power-metrics-incident-power-w metrics))
        accepted))
  (define reference-label
    (if (real? (power-metrics-incident-power-w metrics)) "% incident" "% accepted"))
  (define rows
    (filter
     values
     (list
      (and (real? (power-metrics-incident-power-w metrics))
           (list "Incident" (power-metrics-incident-power-w metrics)))
      (and (real? (power-metrics-reflected-power-w metrics))
           (list "Reflected" (power-metrics-reflected-power-w metrics)))
      (and (real? accepted) (list "Accepted" accepted))
      (and (real? (power-metrics-air-radiated-power-w metrics))
           (list "Air radiated" (power-metrics-air-radiated-power-w metrics)))
      (and (real? (power-metrics-delivered-power-w metrics))
           (list "Delivered to output ports"
                 (power-metrics-delivered-power-w metrics)))
      (and (real? (power-metrics-structure-loss-w metrics))
           (list "Structure loss" (power-metrics-structure-loss-w metrics)))
      (and (real? (power-metrics-network-loss-w metrics))
           (list "Network loss" (power-metrics-network-loss-w metrics)))
      (and (real? (power-metrics-dielectric-loss-w metrics))
           (list "Dielectric loss" (power-metrics-dielectric-loss-w metrics)))
      (and (real? (power-metrics-lumped-loss-w metrics))
           (list "Lumped-element loss" (power-metrics-lumped-loss-w metrics)))
      (and (real? (power-metrics-residual-loss-w metrics))
           (list (case (power-metrics-residual-label metrics)
                   [(ground-or-unaccounted) "Ground / unaccounted loss"]
                   [(conductor-or-unaccounted) "Conductor / unaccounted loss"]
                   [(unaccounted) "Unaccounted / integration error"]
                   [else "Residual loss"])
                 (power-metrics-residual-loss-w metrics))))))
  (string-append
   (format "Power report — ~a~a at ~a MHz\n\n"
           (power-metrics-backend metrics)
           (if (power-metrics-excitation metrics)
               (format " · ~a" (power-metrics-excitation metrics)) "")
           (~r (power-metrics-frequency-mhz metrics) #:precision '(= 6)))
   (format "~a ~a ~a ~a\n"
           (~a "Power flow" #:min-width 30 #:align 'left)
           (~a "watts" #:min-width 20 #:align 'right)
           (~a reference-label #:min-width 11 #:align 'right)
           (~a "dB" #:min-width 11 #:align 'right))
   (make-string 75 #\-)
   "\n"
   (string-join
    (for/list ([row (in-list rows)])
      (power-row (first row) (second row) table-reference))
    "\n")
   "\n\n"
   (format "Radiation efficiency       ~a  (~a)\n"
           (format-percent (power-metrics-radiation-efficiency metrics))
           (format-db-ratio (power-metrics-radiation-efficiency metrics)))
   (format "Mismatch efficiency        ~a  (~a)\n"
           (format-percent (power-metrics-mismatch-efficiency metrics))
           (format-db-ratio (power-metrics-mismatch-efficiency metrics)))
   (format "Realized efficiency        ~a  (~a)\n"
           (format-percent (power-metrics-realized-efficiency metrics))
           (format-db-ratio (power-metrics-realized-efficiency metrics)))
   (if (real? (power-metrics-gain-integral-sr metrics))
       (format "Integrated power gain      ~a sr over ~a sr sampled\n"
               (~r (power-metrics-gain-integral-sr metrics) #:precision '(= 6))
               (~r (power-metrics-sampled-solid-angle-sr metrics)
                   #:precision '(= 6)))
       "")
   (if (power-metrics-angular-resolution-deg metrics)
       (format "Angular resolution         ~a° azimuth × ~a° elevation\n"
               (first (power-metrics-angular-resolution-deg metrics))
               (second (power-metrics-angular-resolution-deg metrics)))
       "")
   (if (null? (power-metrics-notes metrics))
       ""
       (string-append
        "\n"
        (string-join
         (for/list ([note (in-list (power-metrics-notes metrics))])
           (format "Note: ~a" note))
         "\n")
        "\n"))))

(define (power-report [source #f]
                      #:frequency [frequency (model-frequency)]
                      #:theta-step [theta-step 2]
                      #:phi-step [phi-step 2]
                      #:reference-impedance
                      [reference-impedance (model-impedance)]
                      #:output [out (current-output-port)])
  (define actual-source
    (or source
        (nec2c-radiation-grid #:frequency frequency
                              #:theta-step theta-step
                              #:phi-step phi-step)))
  (display (format-power-report actual-source
                                #:reference-impedance reference-impedance)
           out)
  (void))
