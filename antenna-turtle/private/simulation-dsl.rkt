#lang racket/base

(require racket/list
         "openems.rkt"
         "simulation-profile.rkt"
         (for-syntax racket/base racket/list syntax/parse))

(provide simulate radiation-pattern)

(define (run-openems-simulation start-mhz stop-mhz profile
                                #:octave [octave #f]
                                #:keep-artifacts? [keep-artifacts? #t]
                                #:progress? [progress? #t]
                                #:timeout [timeout #f])
  (unless (simulation-profile? profile)
    (raise-argument-error 'simulate "simulation-profile?" profile))
  (openems-sweep
   start-mhz stop-mhz
   #:steps (simulation-profile-frequency-steps profile)
   #:cells-per-wavelength
   (simulation-profile-cells-per-wavelength profile)
   #:minimum-dielectric-cells
   (simulation-profile-minimum-dielectric-cells profile)
   #:minimum-trace-cells
   (simulation-profile-minimum-trace-cells profile)
   #:metal-edge-resolution
   (simulation-profile-metal-edge-resolution profile)
   #:mesh-grading (simulation-profile-mesh-grading profile)
   #:padding-wavelengths
   (simulation-profile-padding-wavelengths profile)
   #:max-timesteps (simulation-profile-maximum-timesteps profile)
   #:end-criteria (simulation-profile-end-criteria profile)
   #:wire-segments (simulation-profile-wire-segments profile)
   #:octave octave
   #:keep-artifacts? keep-artifacts?
   #:progress? progress?
   #:timeout timeout))

(begin-for-syntax
  (define (parse-settings stx items)
    (define values (syntax->list items))
    (when (odd? (length values))
      (raise-syntax-error
       'simulate "expected setting/value pairs" stx))
    (define result (make-hasheq))
    (for ([offset (in-range 0 (length values) 2)])
      (define key-stx (list-ref values offset))
      (unless (identifier? key-stx)
        (raise-syntax-error
         'simulate "expected a contextual setting name" stx key-stx))
      (define key (syntax-e key-stx))
      (unless (memq key
                    '(engine sweep profile octave keep-artifacts progress timeout))
        (raise-syntax-error
         'simulate
         (string-append
          "expected engine, sweep, profile, octave, keep-artifacts, "
          "progress, or timeout setting")
         stx key-stx))
      (when (hash-has-key? result key)
        (raise-syntax-error
         'simulate "setting may be specified only once" stx key-stx))
      (hash-set! result key (list-ref values (add1 offset))))
    result)

  (define (optional-keyword settings key keyword)
    (if (hash-has-key? settings key)
        (list keyword (hash-ref settings key))
        '())))

(define-syntax (simulate stx)
  (syntax-parse stx
    [(_ setting ...)
     (define settings (parse-settings stx #'(setting ...)))
     (define engine (hash-ref settings 'engine #f))
     (unless (and (identifier? engine) (eq? (syntax-e engine) 'openems))
       (raise-syntax-error
        'simulate "the supported engine is openems" stx engine))
     (define sweep (hash-ref settings 'sweep #f))
     (unless sweep
       (raise-syntax-error 'simulate "sweep is required" stx))
     (define profile (hash-ref settings 'profile #'standard))
     #`(let ([frequency-range #,sweep])
         (unless (and (list? frequency-range)
                      (= (length frequency-range) 2))
           (raise-argument-error
            'simulate "two-element frequency sweep list" frequency-range))
         (run-openems-simulation
          (first frequency-range) (second frequency-range) #,profile
          #,@(optional-keyword settings 'octave #'#:octave)
          #,@(optional-keyword
              settings 'keep-artifacts #'#:keep-artifacts?)
          #,@(optional-keyword settings 'progress #'#:progress?)
          #,@(optional-keyword settings 'timeout #'#:timeout)))]))

;; Near-field recording already belongs to the simulation result. This name
;; makes its later, possibly cached NF2FF calculation explicit postprocessing.
(define radiation-pattern openems-radiation-grid)
