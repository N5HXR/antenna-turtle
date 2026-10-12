#lang racket/base

(require racket/file
         racket/format
         racket/list
         racket/match
         racket/math
         racket/path
         racket/string
         "nec2c.rkt"
         "openems.rkt")

(provide
 (struct-out openems-power-budget)
 power-budget
 format-power-budget
 display-power-budget)

;; All powers are solver-average watts at one frequency.  Conductor loss is
;; deliberately paired with the numerical remainder: openEMS conducting
;; sheets use a surface model that is not represented in the volumetric SAR
;; dump, so conservation gives the useful revision-1 aggregate without
;; claiming that numerical closure error is physical heat.
(struct openems-power-budget
  (run frequency-mhz excitation-port
       incident-power-w reflected-power-w accepted-power-w
       delivered-power-w radiated-power-w dielectric-power-w lumped-power-w
       conductor-and-unaccounted-power-w)
  #:transparent)

(define (result-run result)
  (cond
    [(openems-sweep-result? result) (openems-sweep-result-run result)]
    [(openems-multiport-result? result) (openems-multiport-result-run result)]
    [else
     (raise-argument-error
      'power-budget
      "(or/c openems-sweep-result? openems-multiport-result?)"
      result)]))

(define (result-ports result)
  (if (openems-multiport-result? result)
      (openems-multiport-result-ports result)
      (list
       (openems-result-port
        (openems-sweep-result-port-name result)
        (openems-sweep-result-reference-impedance result)))))

(define (resolve-excitation who result requested)
  (define ports (result-ports result))
  (define selected
    (if requested
        (for/first ([port (in-list ports)]
                    #:when
                    (equal? (format "~a" (openems-result-port-name port))
                            (format "~a" requested)))
          port)
        (first ports)))
  (unless selected
    (raise-arguments-error
     who "unknown excitation port"
     "excitation" requested
     "available ports" (map openems-result-port-name ports)))
  (values selected (add1 (index-of ports selected))))

(define (numeric-csv path expected-fields who)
  (unless (file-exists? path)
    (raise-user-error
     who
     (string-append
      "the simulation has no ~a; run it again with the current Antenna "
      "Turtle OpenEMS harness")
     (path->string (file-name-from-path path))))
  (for/list ([line (in-list (file->lines path))]
             #:unless (string=? (string-trim line) ""))
    (define fields (map string->number (string-split line ",")))
    (unless (and (= (length fields) expected-fields) (andmap number? fields))
      (error who "invalid power result row in ~a: ~e" path line))
    fields))

(define (excitation-directory artifacts port-count excitation-index)
  (define simulation (openems-artifacts-simulation-directory artifacts))
  (if (= port-count 1)
      simulation
      (build-path simulation (format "excitation-~a" excitation-index))))

(define (close-enough? left right)
  (<= (abs (- left right)) (* 1e-9 (max 1 (abs left) (abs right)))))

(define (nonnegative-roundoff value reference)
  (if (and (negative? value)
           (<= (abs value) (* 1e-9 (max 1 (abs reference)))))
      0.0
      value))

(define (power-budget result
                      #:frequency [requested-frequency #f]
                      #:excitation [requested-excitation #f]
                      #:theta-step [theta-step 2]
                      #:phi-step [phi-step 2]
                      #:octave [octave #f]
                      #:reuse? [reuse? #t]
                      #:timeout [timeout #f])
  (define run (result-run result))
  (define manifest (openems-run-info-manifest run))
  (define recorded-frequency (hash-ref manifest 'model_frequency_mhz))
  (define frequency (or requested-frequency recorded-frequency))
  (unless (and (real? frequency) (positive? frequency))
    (raise-argument-error 'power-budget "positive-real?" frequency))
  (unless (close-enough? frequency recorded-frequency)
    (raise-arguments-error
     'power-budget
     (string-append
      "material-loss accounting was recorded only at the model frequency; "
      "change the model frequency and rerun to report another frequency")
     "requested frequency (MHz)" frequency
     "recorded frequency (MHz)" recorded-frequency))
  (define ports (result-ports result))
  (define-values (excitation-port excitation-index)
    (resolve-excitation 'power-budget result requested-excitation))
  (define artifacts (openems-run-info-artifacts run))
  (unless (and (openems-artifacts-available? artifacts)
               (directory-exists? (openems-artifacts-directory artifacts)))
    (raise-user-error 'power-budget
                      "the OpenEMS field artifacts have been released"))
  (define simulation-directory
    (excitation-directory artifacts (length ports) excitation-index))
  (define port-rows
    (numeric-csv (build-path simulation-directory "port-power.csv") 6
                 'power-budget))
  (define active-row
    (for/first ([row (in-list port-rows)]
                #:when (= (list-ref row 1) excitation-index))
      row))
  (unless active-row
    (error 'power-budget "port-power data has no active excitation row"))
  (match-define
    (list _frequency-hz _port-index _active-index incident reflected accepted)
    active-row)
  (define delivered
    (for/sum ([row (in-list port-rows)]
              #:unless (= (list-ref row 1) excitation-index))
      (max 0 (- (list-ref row 5)))))
  (define dielectric-rows
    (numeric-csv (build-path simulation-directory "dielectric-power.csv") 3
                 'power-budget))
  (define dielectric
    (if (null? dielectric-rows) 0 (list-ref (first dielectric-rows) 2)))
  (define lumped-rows
    (numeric-csv (build-path simulation-directory "lumped-power.csv") 4
                 'power-budget))
  (define lumped
    (for/sum ([row (in-list lumped-rows)]) (list-ref row 3)))
  ;; NF2FF is intentionally deferred: calculating a budget should not force a
  ;; dense radiation pattern during every FDTD run, and the result is cached.
  (define pattern
    (openems-radiation-grid
     result
     #:frequency frequency
     #:excitation (openems-result-port-name excitation-port)
     #:theta-step theta-step
     #:phi-step phi-step
     #:octave octave
     #:reuse? reuse?
     #:timeout timeout))
  (define pattern-metadata (nec2c-pattern-grid-run pattern))
  (define radiated (hash-ref pattern-metadata 'radiated_power_w))
  (define updated-run (hash-ref pattern-metadata 'run run))
  (define remainder
    (nonnegative-roundoff
     (- accepted delivered radiated dielectric lumped)
     accepted))
  (openems-power-budget
   updated-run frequency (openems-result-port-name excitation-port)
   incident reflected accepted delivered radiated dielectric lumped remainder))

(define (power-db power incident)
  (cond
    [(<= power 0) -inf.0]
    [(<= incident 0) +nan.0]
    [else (* 10 (/ (log (/ power incident)) (log 10)))]))

(define (power-percent power incident)
  (if (zero? incident) +nan.0 (* 100 (/ power incident))))

(define (format-db value)
  (cond [(eqv? value -inf.0) "-inf"]
        [(nan? value) "nan"]
        [else (~r value #:precision '(= 2))]))

(define (format-power-budget budget)
  (unless (openems-power-budget? budget)
    (raise-argument-error 'format-power-budget "openems-power-budget?" budget))
  (define incident (openems-power-budget-incident-power-w budget))
  (define rows
    (list
     (list "Incident" incident)
     (list "Reflected" (openems-power-budget-reflected-power-w budget))
     (list "Delivered to output ports"
           (openems-power-budget-delivered-power-w budget))
     (list "Radiated" (openems-power-budget-radiated-power-w budget))
     (list "Dielectric heat" (openems-power-budget-dielectric-power-w budget))
     (list "Lumped-element heat" (openems-power-budget-lumped-power-w budget))
     (list "Conductors / numerical remainder"
           (openems-power-budget-conductor-and-unaccounted-power-w budget))))
  (define body
    (string-join
     (for/list ([row (in-list rows)])
       (match-define (list label power) row)
       (format "~a~a W  ~a%  ~a dB"
               (~a label #:min-width 34 #:align 'left)
               (~r power #:notation 'exponential
                   #:precision 6 #:min-width 14)
               (~r (power-percent power incident)
                   #:precision '(= 2) #:min-width 8)
               (~a (format-db (power-db power incident))
                   #:min-width 8 #:align 'right)))
     "\n"))
  (define accepted (openems-power-budget-accepted-power-w budget))
  (define radiation-efficiency
    (if (zero? accepted)
        +nan.0
        (* 100 (/ (openems-power-budget-radiated-power-w budget) accepted))))
  (string-append
   (format "Power budget — ~a excitation at ~a MHz\n\n"
           (openems-power-budget-excitation-port budget)
           (~r (openems-power-budget-frequency-mhz budget)
               #:precision '(= 6)))
   body
   (format "\n\nAccepted power~a W\nRadiation efficiency~a%\n"
           (~r accepted #:notation 'exponential
               #:precision 6 #:min-width 20)
           (~r radiation-efficiency #:precision '(= 2) #:min-width 14))
   "The final category includes conducting-sheet loss and power-balance error.\n"))

(define (display-power-budget budget [out (current-output-port)])
  (display (format-power-budget budget) out)
  (void))
