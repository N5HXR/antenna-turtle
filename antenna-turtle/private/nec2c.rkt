#lang racket/base

(require racket/file
         racket/list
         racket/math
         racket/path
         racket/port
         racket/string
         "core.rkt"
         "export-common.rkt"
         "export-nec2c.rkt"
         "network.rkt")

(provide
 nec2c-executable
 (struct-out nec2c-artifacts)
 (struct-out nec2c-run-info)
 (struct-out nec2c-feedpoint-sample)
 (struct-out nec2c-impedance-result)
 (struct-out nec2c-sweep-sample)
 (struct-out nec2c-sweep-frequency)
 (struct-out nec2c-sweep-result)
 (struct-out nec2c-pattern-sample)
 (struct-out nec2c-pattern)
 (struct-out nec2c-pattern-grid)
 (struct-out nec2c-segment-sample)
 (struct-out nec2c-power-budget)
 (struct-out nec2c-diagnostics)
 near-field-section
 near-field-section?
 near-field-section-plane
 near-field-section-position
 near-field-section-x-range
 near-field-section-y-range
 near-field-section-z-range
 near-field-section-samples
 near-field-section-fields
 (struct-out nec2c-near-field-sample)
 (struct-out nec2c-near-field-section)
 (struct-out nec2c-near-field-result)
 (struct-out nec2c-gain-sweep-sample)
 (struct-out nec2c-gain-sweep-result)
 (struct-out parsed-nec2c-feed)
 (struct-out parsed-nec2c-pattern)
 (struct-out parsed-nec2c-segment-current)
 (struct-out parsed-nec2c-segment-charge)
 (struct-out parsed-nec2c-power-budget)
 (struct-out parsed-nec2c-near-field)
 (struct-out parsed-nec2c-report)
 (struct-out exn:fail:nec2c)
 parse-nec2c-output
 nec2c-measure-impedance
 nec2c-vswr-sweep
 nec2c-sweep->network-sweep
 nec2c-azimuth-pattern
 nec2c-elevation-pattern
 nec2c-radiation-grid
 nec2c-segment-diagnostics
 nec2c-near-field-planes
 nec2c-gain-sweep
 nec2c-gain-sweep->network-sweep)

(struct nec2c-artifacts
  (model-path input-path output-path temporary? available?)
  #:transparent)

(struct nec2c-run-info
  (executable version elapsed-ms exit-code stdout stderr artifacts)
  #:transparent)

(struct nec2c-feedpoint-sample
  (feed-name frequency-mhz wire-id segment
   voltage current impedance admittance input-power)
  #:transparent)

(struct nec2c-impedance-result (run samples) #:transparent)

(struct nec2c-sweep-sample
  (feedpoint reflection-coefficient return-loss-db vswr)
  #:transparent)

(struct nec2c-sweep-frequency (frequency-mhz feed-samples) #:transparent)

(struct nec2c-sweep-result
  (run reference-impedance frequencies)
  #:transparent)

(struct nec2c-pattern-sample
  (frequency-mhz theta-deg phi-deg elevation-deg azimuth-deg
   vertical-gain-db horizontal-gain-db total-gain-db
   axial-ratio tilt-deg polarization-sense
   e-theta e-phi [direction #:auto #:mutable])
  #:auto-value #f
  #:transparent)

(struct nec2c-pattern (run kind fixed-angle samples) #:transparent)
(struct nec2c-pattern-grid
  (run theta-values phi-values samples [diagnostics #:auto #:mutable])
  #:auto-value #f
  #:transparent)

(struct nec2c-segment-sample
  (frequency-mhz wire-id segment current charge-density)
  #:transparent)
(struct nec2c-power-budget
  (frequency-mhz input-power radiated-power structure-loss network-loss efficiency-percent)
  #:transparent)
(struct nec2c-diagnostics (frequency-mhz segments power-budget) #:transparent)

;; A plane request is deliberately solver-neutral in its surface syntax.  The
;; symbolic x/y/z forms name the plane normal; xy/xz/yz name the axes contained
;; by the plane.  Missing position and ranges are resolved from the feed
;; centroid, model bounds, and wavelength when the request is run.
(struct requested-near-field-section
  (plane position x-range y-range z-range samples fields)
  #:transparent)
(define near-field-section? requested-near-field-section?)
(define near-field-section-plane requested-near-field-section-plane)
(define near-field-section-position requested-near-field-section-position)
(define near-field-section-x-range requested-near-field-section-x-range)
(define near-field-section-y-range requested-near-field-section-y-range)
(define near-field-section-z-range requested-near-field-section-z-range)
(define near-field-section-samples requested-near-field-section-samples)
(define near-field-section-fields requested-near-field-section-fields)

(struct nec2c-near-field-sample (x y z electric magnetic) #:transparent)
(struct nec2c-near-field-section
  (plane normal-axis position u-axis v-axis u-values v-values samples fields)
  #:transparent)
(struct nec2c-near-field-result (run frequency-mhz sections diagnostics) #:transparent)

;; A gain sweep deliberately retains the complete pattern grid at every
;; frequency.  Besides supporting the summary curves, that lets callers open
;; an interesting frequency in the ordinary 3-D pattern viewers without
;; rerunning NEC2C.
(struct nec2c-gain-sweep-sample
  (frequency-mhz feedpoint reflection-coefficient return-loss-db vswr
   pattern maximum-gain-db realized-maximum-gain-db maximum-gain-direction
   horizon-gain-db realized-horizon-gain-db)
  #:transparent)

(struct nec2c-gain-sweep-result
  (run reference-impedance samples)
  #:transparent)

;; Parser-facing values deliberately retain NEC coordinates and source tags.
;; The runner enriches these with Antenna Turtle feed names and friendly angles.
(struct parsed-nec2c-feed
  (frequency-mhz tag segment voltage current impedance admittance input-power)
  #:transparent)
(struct parsed-nec2c-pattern
  (frequency-mhz theta-deg phi-deg
   vertical-gain-db horizontal-gain-db total-gain-db
   axial-ratio tilt-deg polarization-sense e-theta e-phi)
  #:transparent)
(struct parsed-nec2c-segment-current
  (frequency-mhz segment tag x-wavelengths y-wavelengths z-wavelengths
                 length-wavelengths current)
  #:transparent)
(struct parsed-nec2c-segment-charge
  (frequency-mhz segment tag x-wavelengths y-wavelengths z-wavelengths
                 length-wavelengths charge-density)
  #:transparent)
(struct parsed-nec2c-power-budget
  (frequency-mhz input-power radiated-power structure-loss network-loss efficiency-percent)
  #:transparent)
(struct parsed-nec2c-near-field
  (frequency-mhz quantity x y z x-component y-component z-component)
  #:transparent)
(struct parsed-nec2c-report
  (feeds patterns
         [currents #:auto #:mutable]
         [charges #:auto #:mutable]
         [power-budgets #:auto #:mutable]
         [near-fields #:auto #:mutable])
  #:auto-value '()
  #:transparent)

(struct exn:fail:nec2c exn:fail (run-info) #:transparent)

(define (nec2c-sweep->network-sweep result)
  (unless (nec2c-sweep-result? result)
    (raise-argument-error
     'nec2c-sweep->network-sweep "nec2c-sweep-result?" result))
  (network-sweep
   'nec2c
   (nec2c-sweep-result-run result)
   (nec2c-sweep-result-reference-impedance result)
   (for*/list ([frequency
                (in-list (nec2c-sweep-result-frequencies result))]
               [sample
                (in-list (nec2c-sweep-frequency-feed-samples frequency))])
     (define feedpoint (nec2c-sweep-sample-feedpoint sample))
     (network-sample
      (nec2c-feedpoint-sample-feed-name feedpoint)
      (nec2c-feedpoint-sample-frequency-mhz feedpoint)
      (nec2c-sweep-sample-reflection-coefficient sample)
      (nec2c-feedpoint-sample-impedance feedpoint)
      (- (nec2c-sweep-sample-return-loss-db sample))
      (nec2c-sweep-sample-vswr sample)))))

(define (nec2c-gain-sweep->network-sweep result)
  (unless (nec2c-gain-sweep-result? result)
    (raise-argument-error
     'nec2c-gain-sweep->network-sweep "nec2c-gain-sweep-result?" result))
  (network-sweep
   'nec2c
   (nec2c-gain-sweep-result-run result)
   (nec2c-gain-sweep-result-reference-impedance result)
   (for/list ([sample (in-list (nec2c-gain-sweep-result-samples result))])
     (define feedpoint (nec2c-gain-sweep-sample-feedpoint sample))
     (network-sample
      (nec2c-feedpoint-sample-feed-name feedpoint)
      (nec2c-gain-sweep-sample-frequency-mhz sample)
      (nec2c-gain-sweep-sample-reflection-coefficient sample)
      (nec2c-feedpoint-sample-impedance feedpoint)
      (- (nec2c-gain-sweep-sample-return-loss-db sample))
      (nec2c-gain-sweep-sample-vswr sample)))))

(define nec2c-executable
  (make-parameter
   #f
   (lambda (value)
     (unless (or (not value) (path-string? value))
       (raise-argument-error 'nec2c-executable "(or/c #f path-string?)" value))
     value)))

(define numeric-token-rx
  #px"^[+-]?(?:[0-9]+(?:[.][0-9]*)?|[.][0-9]+)(?:[Ee][+-]?[0-9]+)?$")

(define (finite-real? value)
  (and (real? value)
       (not (nan? (exact->inexact value)))
       (not (infinite? (exact->inexact value)))))

(define (normalize-plane plane)
  (case plane
    [(x yz) 'yz]
    [(y xz) 'xz]
    [(z xy) 'xy]
    [else
     (raise-argument-error
      'near-field-section "(or/c 'x 'y 'z 'xy 'xz 'yz)" plane)]))

(define (validate-range who value)
  (unless (or (not value)
              (and (list? value) (= (length value) 2)
                   (andmap finite-real? value) (< (first value) (second value))))
    (raise-argument-error who "(or/c #f (list/c finite-real? finite-real?))" value))
  value)

(define (normalize-plane-samples value)
  (define result
    (cond [(exact-integer? value) (list value value)]
          [(and (list? value) (= (length value) 2)) value]
          [else #f]))
  (unless (and result (andmap (lambda (count) (and (exact-integer? count) (>= count 2))) result))
    (raise-argument-error 'near-field-section
                          "an integer >= 2 or a two-element list of integers >= 2"
                          value))
  result)

(define (near-field-section #:plane [plane 'xy]
                            #:position [position #f]
                            #:x-range [x-range #f]
                            #:y-range [y-range #f]
                            #:z-range [z-range #f]
                            #:samples [samples 121]
                            #:fields [fields '(electric magnetic)])
  (define normalized-plane (normalize-plane plane))
  (unless (or (not position) (finite-real? position))
    (raise-argument-error 'near-field-section "(or/c #f finite-real?)" position))
  (for ([range (in-list (list x-range y-range z-range))])
    (validate-range 'near-field-section range))
  (unless (and (list? fields) (pair? fields)
               (andmap (lambda (field) (memq field '(electric magnetic))) fields)
               (= (length fields) (length (remove-duplicates fields))))
    (raise-argument-error
     'near-field-section
     "a nonempty duplicate-free list containing 'electric and/or 'magnetic"
     fields))
  (requested-near-field-section
   normalized-plane position x-range y-range z-range
   (normalize-plane-samples samples) fields))

(define (numeric-token? token)
  (and (regexp-match? numeric-token-rx token)
       (number? (string->number token))))

(define (token-number who token)
  (define value (and (numeric-token? token) (string->number token)))
  (unless value (error who "invalid numeric token in NEC2C report: ~e" token))
  value)

(define (complex-from-parts real-token imaginary-token)
  (make-rectangular (token-number 'parse-nec2c-output real-token)
                    (token-number 'parse-nec2c-output imaginary-token)))

(define (complex-from-polar magnitude-token phase-token)
  (make-polar (token-number 'parse-nec2c-output magnitude-token)
              (degrees->radians
               (token-number 'parse-nec2c-output phase-token))))

(define (gain-token token)
  (define value (token-number 'parse-nec2c-output token))
  (if (<= value -999) #f value))

(define (parse-feed-row frequency tokens)
  (and (= (length tokens) 11)
       (andmap numeric-token? tokens)
       (let ([values (map string->number tokens)])
         (and (exact-integer? (list-ref values 0))
              (exact-integer? (list-ref values 1))
              (parsed-nec2c-feed
               frequency
               (list-ref values 0)
               (list-ref values 1)
               (make-rectangular (list-ref values 2) (list-ref values 3))
               (make-rectangular (list-ref values 4) (list-ref values 5))
               (make-rectangular (list-ref values 6) (list-ref values 7))
               (make-rectangular (list-ref values 8) (list-ref values 9))
               (list-ref values 10))))))

(define polarization-words '("LINEAR" "RIGHT" "LEFT"))

(define (parse-pattern-row frequency tokens)
  (define has-sense?
    (and (= (length tokens) 12)
         (member (list-ref tokens 7) polarization-words)))
  (define no-sense? (= (length tokens) 11))
  (and (or has-sense? no-sense?)
       (let* ([sense (and has-sense? (string-downcase (list-ref tokens 7)))]
              [numeric (if has-sense?
                           (append (take tokens 7) (drop tokens 8))
                           tokens)])
         (and (= (length numeric) 11)
              (andmap numeric-token? numeric)
              (parsed-nec2c-pattern
               frequency
               (token-number 'parse-nec2c-output (list-ref numeric 0))
               (token-number 'parse-nec2c-output (list-ref numeric 1))
               (gain-token (list-ref numeric 2))
               (gain-token (list-ref numeric 3))
               (gain-token (list-ref numeric 4))
               (token-number 'parse-nec2c-output (list-ref numeric 5))
               (token-number 'parse-nec2c-output (list-ref numeric 6))
               (and sense (string->symbol sense))
               (complex-from-polar (list-ref numeric 7) (list-ref numeric 8))
               (complex-from-polar (list-ref numeric 9) (list-ref numeric 10)))))))

(define (parse-segment-row constructor frequency tokens)
  (and (= (length tokens) 10)
       (andmap numeric-token? tokens)
       (let ([values (map string->number tokens)])
         (and (exact-integer? (list-ref values 0))
              (exact-integer? (list-ref values 1))
              (constructor
               frequency
               (list-ref values 0)
               (list-ref values 1)
               (list-ref values 2)
               (list-ref values 3)
               (list-ref values 4)
               (list-ref values 5)
               (make-rectangular (list-ref values 6) (list-ref values 7)))))))

(define (parse-near-field-row frequency quantity tokens)
  (and (= (length tokens) 9)
       (andmap numeric-token? tokens)
       (let ([values (map string->number tokens)])
         (parsed-nec2c-near-field
          frequency quantity
          (list-ref values 0) (list-ref values 1) (list-ref values 2)
          (complex-from-polar (list-ref tokens 3) (list-ref tokens 4))
          (complex-from-polar (list-ref tokens 5) (list-ref tokens 6))
          (complex-from-polar (list-ref tokens 7) (list-ref tokens 8))))))

(define power-value-rx
  #px"=[[:space:]]*([^[:space:]]+)[[:space:]]+(?:Watts|Percent)")

(define (parse-power-value line)
  (define match (regexp-match power-value-rx line))
  (and match (token-number 'parse-nec2c-output (list-ref match 1))))

(define frequency-rx
  #px"FREQUENCY[[:space:]]*:[[:space:]]*([^[:space:]]+)[[:space:]]+MHz")

(define (parse-nec2c-output source)
  (define text
    (cond [(input-port? source) (port->string source)]
          [(and (string? source) (file-exists? source)) (file->string source)]
          [(string? source) source]
          [(path? source) (file->string source)]
          [else
           (raise-argument-error
            'parse-nec2c-output
            "(or/c input-port? string? path?)"
            source)]))
  (define frequency #f)
  (define mode #f)
  (define rows-started? #f)
  (define feeds '())
  (define patterns '())
  (define currents '())
  (define charges '())
  (define power-budgets '())
  (define near-fields '())
  (define input-power #f)
  (define radiated-power #f)
  (define structure-loss #f)
  (define network-loss #f)
  (for ([line (in-list (string-split text "\n" #:trim? #f))])
    (define frequency-match (regexp-match frequency-rx line))
    (cond
      [frequency-match
       (set! frequency
             (token-number 'parse-nec2c-output (list-ref frequency-match 1)))
       (set! mode #f)
       (set! rows-started? #f)]
      [(string-contains? line "ANTENNA INPUT PARAMETERS")
       (set! mode 'feeds)
       (set! rows-started? #f)]
      [(string-contains? line "RADIATION PATTERNS")
       (set! mode 'patterns)
       (set! rows-started? #f)]
      [(string-contains? line "CURRENTS AND LOCATION")
       (set! mode 'currents)
       (set! rows-started? #f)]
      [(string-contains? line "CHARGE DENSITIES")
       (set! mode 'charges)
       (set! rows-started? #f)]
      [(string-contains? line "POWER BUDGET")
       (set! mode 'power)
       (set! rows-started? #f)
       (set! input-power #f)
       (set! radiated-power #f)
       (set! structure-loss #f)
       (set! network-loss #f)]
      [(string-contains? line "NEAR ELECTRIC FIELDS")
       (set! mode 'near-electric)
       (set! rows-started? #f)]
      [(string-contains? line "NEAR MAGNETIC FIELDS")
       (set! mode 'near-magnetic)
       (set! rows-started? #f)]
      [(and (eq? mode 'power) (string-contains? line "INPUT POWER"))
       (set! input-power (parse-power-value line))]
      [(and (eq? mode 'power) (string-contains? line "RADIATED POWER"))
       (set! radiated-power (parse-power-value line))]
      [(and (eq? mode 'power) (string-contains? line "STRUCTURE LOSS"))
       (set! structure-loss (parse-power-value line))]
      [(and (eq? mode 'power) (string-contains? line "NETWORK LOSS"))
       (set! network-loss (parse-power-value line))]
      [(and (eq? mode 'power) (string-contains? line "EFFICIENCY"))
       (define efficiency (parse-power-value line))
       (when (and frequency efficiency)
         (set! power-budgets
               (cons (parsed-nec2c-power-budget
                      frequency input-power radiated-power structure-loss
                      network-loss efficiency)
                     power-budgets)))
       (set! mode #f)]
      [else
       (define tokens (string-split (string-trim line)))
       (define parsed
         (and frequency
              (case mode
                [(feeds) (parse-feed-row frequency tokens)]
                [(patterns) (parse-pattern-row frequency tokens)]
                [(currents)
                 (parse-segment-row parsed-nec2c-segment-current frequency tokens)]
                [(charges)
                 (parse-segment-row parsed-nec2c-segment-charge frequency tokens)]
                [(near-electric) (parse-near-field-row frequency 'electric tokens)]
                [(near-magnetic) (parse-near-field-row frequency 'magnetic tokens)]
                [else #f])))
       (cond
         [parsed
          (set! rows-started? #t)
          (case mode
            [(feeds) (set! feeds (cons parsed feeds))]
            [(patterns) (set! patterns (cons parsed patterns))]
            [(currents) (set! currents (cons parsed currents))]
            [(charges) (set! charges (cons parsed charges))]
            [(near-electric near-magnetic)
             (set! near-fields (cons parsed near-fields))])]
         [(and rows-started? (string=? (string-trim line) ""))
          (set! mode #f)
          (set! rows-started? #f)])]))
  (define report (parsed-nec2c-report (reverse feeds) (reverse patterns)))
  (set-parsed-nec2c-report-currents! report (reverse currents))
  (set-parsed-nec2c-report-charges! report (reverse charges))
  (set-parsed-nec2c-report-power-budgets! report (reverse power-budgets))
  (set-parsed-nec2c-report-near-fields! report (reverse near-fields))
  report)

(define (resolve-executable requested)
  (define candidate
    (or requested
        (nec2c-executable)
        (getenv "NEC2C")
        (find-executable-path "nec2c")))
  (unless candidate
    (raise-user-error
     'nec2c
     "could not find nec2c; set (nec2c-executable), the NEC2C environment variable, or PATH"))
  (define complete (simplify-path (path->complete-path candidate)))
  (unless (file-exists? complete)
    (raise-user-error 'nec2c "executable does not exist: ~a" complete))
  complete)

(define (run-command executable arguments stdout-path stderr-path timeout
                     [working-directory #f])
  (define started (current-inexact-milliseconds))
  (define environment (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! environment #"LC_ALL" #"C")
  (define-values (process timed-out?)
    (parameterize ([current-environment-variables environment]
                   [current-directory
                    (or working-directory (current-directory))])
      (call-with-output-file stdout-path
        #:exists 'truncate/replace
        (lambda (stdout)
          (call-with-output-file stderr-path
            #:exists 'truncate/replace
            (lambda (stderr)
              (define-values (process _stdout stdin _stderr)
                (apply subprocess stdout #f stderr executable arguments))
              (close-output-port stdin)
              (define completed
                (with-handlers
                    ([exn:break?
                      (lambda (failure)
                        ;; Do not leave an unlimited solver run behind when
                        ;; the enclosing Racket program is interrupted.
                        (subprocess-kill process #t)
                        (sync process)
                        (raise failure))])
                  (if timeout
                      (sync/timeout timeout process)
                      (sync process))))
              (unless completed
                (subprocess-kill process #t)
                (sync process))
              (values process (and timeout (not completed)))))))))
  (values (subprocess-status process)
          timed-out?
          (- (current-inexact-milliseconds) started)))

(define (read-version executable directory timeout)
  (define stdout-path (build-path directory "version.stdout"))
  (define stderr-path (build-path directory "version.stderr"))
  (define-values (status timed-out? _elapsed)
    (run-command executable '("-v") stdout-path stderr-path timeout))
  (define combined
    (string-trim
     (string-append (file->string stdout-path) (file->string stderr-path))))
  (if (and (not timed-out?) (zero? status) (not (string=? combined "")))
      combined
      "unknown"))

(define (decorate-deck source destination analysis-cards)
  (define lines (file->lines source))
  (define without-end
    (filter (lambda (line) (not (regexp-match? #px"^[[:space:]]*EN[[:space:]]*$" line)))
            lines))
  (call-with-output-file destination
    #:exists 'truncate/replace
    (lambda (out)
      (for ([line (in-list without-end)]) (displayln line out))
      (for ([card (in-list analysis-cards)]) (displayln card out))
      (displayln "EN" out))))

(define (feed-edges)
  (filter wire-edge-feed? (model-edges)))

(define ground-card-rx
  #px"(?i:^[[:space:]]*GN[[:space:],]+(-?[0-9]+))")

(define (deck-grounded? path)
  (for/fold ([grounded? #f]) ([line (in-list (file->lines path))])
    (define match (regexp-match ground-card-rx line))
    (if match
        (not (= (string->number (second match)) -1))
        grounded?)))

;; Explicit or previously exported decks are authoritative. Otherwise the
;; current model setting determines the angular domain requested from NEC2C.
(define (analysis-grounded? requested-model-path)
  (define base-path
    (or requested-model-path (last-nec2c-export-path)))
  (if (and base-path (file-exists? base-path))
      (deck-grounded? base-path)
      (model-grounded?)))

(define (require-feeds who)
  (define feeds (feed-edges))
  (when (null? feeds)
    (raise-user-error who "the current model has no feed"))
  feeds)

(define (run-nec2c analysis-cards
                    #:model-path [requested-model-path #f]
                    #:executable [requested-executable #f]
                    #:keep-artifacts? [keep? #f]
                    #:timeout [timeout #f]
                    #:validate-report [validate-report values])
  (validate-model!)
  (require-feeds 'nec2c)
  (unless (or (not timeout) (and (real? timeout) (> timeout 0)))
    (raise-argument-error 'nec2c "(or/c #f positive-real?)" timeout))
  (unless (boolean? keep?)
    (raise-argument-error 'nec2c "boolean?" keep?))
  (define executable (resolve-executable requested-executable))
  (define directory
    (make-temporary-file "antenna-turtle-nec2c~a" 'directory))
  (define input-path (build-path directory "analysis.nec"))
  (define output-path (build-path directory "analysis.out"))
  (define stdout-path (build-path directory "nec2c.stdout"))
  (define stderr-path (build-path directory "nec2c.stderr"))
  (define base-path
    (or requested-model-path (last-nec2c-export-path)))
  (with-handlers
      ([exn:fail?
        (lambda (failure)
          ;; Failed runs intentionally retain the complete temporary directory.
          (raise failure))])
    (cond
      [base-path
       (unless (file-exists? base-path)
         (raise-user-error 'nec2c "base NEC model does not exist: ~a" base-path))
       (decorate-deck base-path input-path analysis-cards)]
      [else
       (call-with-output-file input-path
         #:exists 'truncate/replace
         (lambda (out) (write-nec2c-deck out analysis-cards)))])
    (define version (read-version executable directory timeout))
    (define-values (status timed-out? elapsed)
      ;; Classic NEC2C stores its input and output names in a small fixed-size
      ;; buffer. macOS temporary directories (and ordinary Windows paths) can
      ;; exceed that legacy limit, so run inside the artifact directory and
      ;; give NEC2C only short leaf names. The public artifact paths remain
      ;; absolute.
      (run-command executable
                   '("-ianalysis.nec" "-oanalysis.out")
                   stdout-path stderr-path timeout directory))
    (define stdout (file->string stdout-path))
    (define stderr (file->string stderr-path))
    (define artifacts
      (nec2c-artifacts (and base-path (path->complete-path base-path))
                       input-path output-path #t #t))
    (define run
      (nec2c-run-info executable version elapsed status stdout stderr artifacts))
    (when timed-out?
      (raise
       (exn:fail:nec2c
        (format "nec2c timed out after ~a seconds; artifacts retained in ~a"
                timeout directory)
        (current-continuation-marks)
        run)))
    (unless (zero? status)
      (raise
       (exn:fail:nec2c
        (format "nec2c exited with status ~a; artifacts retained in ~a"
                status directory)
        (current-continuation-marks)
        run)))
    (unless (file-exists? output-path)
      (raise
       (exn:fail:nec2c
        (format "nec2c did not create its report; artifacts retained in ~a"
                directory)
        (current-continuation-marks)
        run)))
    (define report
      (with-handlers
          ([exn:fail?
            (lambda (failure)
              (raise
               (exn:fail:nec2c
                (format "could not parse complete NEC2C results: ~a; artifacts retained in ~a"
                        (exn-message failure) directory)
                (exn-continuation-marks failure)
                run)))])
        (define parsed (parse-nec2c-output output-path))
        ;; Run request-specific completeness checks before deleting successful
        ;; temporary artifacts. A malformed or truncated report is therefore
        ;; left intact for diagnosis just like a solver failure.
        (validate-report parsed)
        parsed))
    (define final-run
      (if keep?
          run
          (struct-copy
           nec2c-run-info run
           [artifacts
            (struct-copy nec2c-artifacts artifacts [available? #f])])) )
    (unless keep? (delete-directory/files directory))
    (values final-run report)))

(define (feed-name-for-tag tag)
  (define edge
    (for/first ([candidate (in-list (feed-edges))]
                #:when (= (wire-edge-id candidate) tag))
      candidate))
  (unless edge
    (error 'nec2c "report refers to unknown source tag ~a" tag))
  (wire-edge-feed-name edge))

(define (enrich-feed parsed)
  (nec2c-feedpoint-sample
   (feed-name-for-tag (parsed-nec2c-feed-tag parsed))
   (parsed-nec2c-feed-frequency-mhz parsed)
   (parsed-nec2c-feed-tag parsed)
   (parsed-nec2c-feed-segment parsed)
   (parsed-nec2c-feed-voltage parsed)
   (parsed-nec2c-feed-current parsed)
   (parsed-nec2c-feed-impedance parsed)
   (parsed-nec2c-feed-admittance parsed)
   (parsed-nec2c-feed-input-power parsed)))

(define (enrich-pattern parsed)
  (define theta (parsed-nec2c-pattern-theta-deg parsed))
  (define phi (parsed-nec2c-pattern-phi-deg parsed))
  (nec2c-pattern-sample
   (parsed-nec2c-pattern-frequency-mhz parsed)
   theta phi (- 90 theta) (normalize-degrees phi)
   (parsed-nec2c-pattern-vertical-gain-db parsed)
   (parsed-nec2c-pattern-horizontal-gain-db parsed)
   (parsed-nec2c-pattern-total-gain-db parsed)
   (parsed-nec2c-pattern-axial-ratio parsed)
   (parsed-nec2c-pattern-tilt-deg parsed)
   (parsed-nec2c-pattern-polarization-sense parsed)
   (parsed-nec2c-pattern-e-theta parsed)
   (parsed-nec2c-pattern-e-phi parsed)))

(define (enrich-diagnostics report frequency)
  (define current-frequencies
    (remove-duplicates
     (map parsed-nec2c-segment-current-frequency-mhz
          (parsed-nec2c-report-currents report))))
  (define actual-frequency
    (if (null? current-frequencies)
        frequency
        (argmin (lambda (candidate) (abs (- candidate frequency)))
                current-frequencies)))
  (define charges
    (for/hash ([sample (in-list (parsed-nec2c-report-charges report))]
               #:when (approximately=?
                       actual-frequency
                       (parsed-nec2c-segment-charge-frequency-mhz sample)))
      (values (cons (parsed-nec2c-segment-charge-tag sample)
                    (parsed-nec2c-segment-charge-segment sample))
              (parsed-nec2c-segment-charge-charge-density sample))))
  (define tag-counts (make-hash))
  (define segments
    (for/list ([sample (in-list (parsed-nec2c-report-currents report))]
               #:when (approximately=?
                       actual-frequency
                       (parsed-nec2c-segment-current-frequency-mhz sample)))
      (define wire-id (parsed-nec2c-segment-current-tag sample))
      (define absolute-segment (parsed-nec2c-segment-current-segment sample))
      (define segment (add1 (hash-ref tag-counts wire-id 0)))
      (hash-set! tag-counts wire-id segment)
      (nec2c-segment-sample
       actual-frequency wire-id segment
       (parsed-nec2c-segment-current-current sample)
       (hash-ref charges (cons wire-id absolute-segment) #f))))
  (define parsed-budget
    (for/first ([budget (in-list (parsed-nec2c-report-power-budgets report))]
                #:when (approximately=?
                        actual-frequency
                        (parsed-nec2c-power-budget-frequency-mhz budget)))
      budget))
  (define budget
    (and parsed-budget
         (nec2c-power-budget
          actual-frequency
          (parsed-nec2c-power-budget-input-power parsed-budget)
          (parsed-nec2c-power-budget-radiated-power parsed-budget)
          (parsed-nec2c-power-budget-structure-loss parsed-budget)
          (parsed-nec2c-power-budget-network-loss parsed-budget)
          (parsed-nec2c-power-budget-efficiency-percent parsed-budget))))
  (nec2c-diagnostics actual-frequency segments budget))

(define (number-field who value description)
  (unless (real? value) (raise-argument-error who "real?" value))
  (coordinate-string who value))

(define (frequency-card frequency [count 1] [increment 0])
  (unless (and (real? frequency) (> frequency 0))
    (raise-argument-error 'nec2c "positive frequency in MHz" frequency))
  (unless (exact-positive-integer? count)
    (raise-argument-error 'nec2c "exact-positive-integer?" count))
  (unless (and (real? increment) (>= increment 0))
    (raise-argument-error 'nec2c "nonnegative frequency increment" increment))
  (format "FR 0 ~a 0 0 ~a ~a"
          count
          (number-field 'nec2c frequency "frequency")
          (number-field 'nec2c increment "frequency increment")))

(define (runner-keywords model-path executable keep? timeout cards
                         [validate-report values])
  (run-nec2c cards
             #:model-path model-path
             #:executable executable
             #:keep-artifacts? keep?
             #:timeout timeout
             #:validate-report validate-report))

(define (nec2c-measure-impedance
         [frequency (model-frequency)]
         #:model-path [model-path #f]
         #:executable [executable #f]
         #:keep-artifacts? [keep? #f]
         #:timeout [timeout #f])
  (unless (and (real? frequency) (> frequency 0))
    (raise-argument-error 'nec2c-measure-impedance "positive-real?" frequency))
  (define-values (run report)
    (runner-keywords model-path executable keep? timeout
                     (list "PT -1" (frequency-card frequency) "XQ 0")
                     (lambda (report)
                       (define actual
                         (length (parsed-nec2c-report-feeds report)))
                       (define expected (length (feed-edges)))
                       (unless (= actual expected)
                         (error 'nec2c-measure-impedance
                                "expected ~a feed measurements but parsed ~a"
                                expected actual)))))
  (define samples (map enrich-feed (parsed-nec2c-report-feeds report)))
  (nec2c-impedance-result run samples))

(define (sweep-count-and-increment who start stop steps step)
  (unless (and (real? start) (> start 0))
    (raise-argument-error who "positive-real?" start))
  (unless (and (real? stop) (>= stop start))
    (raise-argument-error who "real value >= start frequency" stop))
  (when (and steps step)
    (raise-arguments-error who "specify either #:steps or #:step, not both"))
  (cond
    [steps
     (unless (exact-integer? steps)
       (raise-argument-error who "exact-integer?" steps))
     (define required-minimum (if (= start stop) 1 2))
     (when (< steps required-minimum)
       (raise-arguments-error who "too few sweep samples" "steps" steps))
     (values steps (if (= steps 1) 0 (/ (- stop start) (sub1 steps))))]
    [step
     (unless (and (real? step) (> step 0))
       (raise-argument-error who "positive-real?" step))
     (define intervals (/ (- stop start) step))
     (define rounded (inexact->exact (round (exact->inexact intervals))))
     (unless (< (abs (- intervals rounded)) 1e-8)
       (raise-arguments-error
        who "#:step must land exactly on the stop frequency"
        "start" start "stop" stop "step" step))
     (values (add1 rounded) step)]
    [else
     (values 101 (if (= start stop) 0 (/ (- stop start) 100)))]))

(define (reflection-metrics impedance reference)
  (define gamma (/ (- impedance reference) (+ impedance reference)))
  (define gamma-magnitude (magnitude gamma))
  (define vswr
    (if (>= gamma-magnitude 1)
        +inf.0
        (/ (+ 1 gamma-magnitude) (- 1 gamma-magnitude))))
  (define return-loss
    (if (zero? gamma-magnitude)
        +inf.0
        (* -20 (/ (log gamma-magnitude) (log 10)))))
  (values gamma return-loss vswr))

(define (nec2c-vswr-sweep
         start stop
         #:steps [steps #f]
         #:step [step #f]
         #:model-path [model-path #f]
         #:executable [executable #f]
         #:keep-artifacts? [keep? #f]
         #:timeout [timeout #f])
  (define-values (count increment)
    (sweep-count-and-increment 'nec2c-vswr-sweep start stop steps step))
  (define-values (run report)
    (runner-keywords model-path executable keep? timeout
                     (list "PT -1" (frequency-card start count increment) "XQ 0")
                     (lambda (report)
                       (define parsed (parsed-nec2c-report-feeds report))
                       (define frequencies
                         (remove-duplicates
                          (map parsed-nec2c-feed-frequency-mhz parsed)))
                       (unless (= (length frequencies) count)
                         (error 'nec2c-vswr-sweep
                                "expected ~a frequencies but parsed ~a"
                                count (length frequencies)))
                       (define expected-rows (* count (length (feed-edges))))
                       (unless (= (length parsed) expected-rows)
                         (error 'nec2c-vswr-sweep
                                "expected ~a feed rows but parsed ~a"
                                expected-rows (length parsed))))))
  (define enriched (map enrich-feed (parsed-nec2c-report-feeds report)))
  (define reference (model-impedance))
  (define frequencies
    (for/list ([frequency (in-list (remove-duplicates
                                    (map nec2c-feedpoint-sample-frequency-mhz
                                         enriched)))])
      (define feed-samples
        (for/list ([feedpoint (in-list enriched)]
                   #:when (= frequency
                             (nec2c-feedpoint-sample-frequency-mhz feedpoint)))
          (define-values (gamma return-loss vswr)
            (reflection-metrics
             (nec2c-feedpoint-sample-impedance feedpoint) reference))
          (nec2c-sweep-sample feedpoint gamma return-loss vswr)))
      (nec2c-sweep-frequency frequency feed-samples)))
  (nec2c-sweep-result run reference frequencies))

(define (angular-sequence who start stop step)
  (unless (and (real? start) (real? stop) (real? step) (> step 0) (>= stop start))
    (raise-arguments-error
     who "expected real angles with stop >= start and positive step"
     "start" start "stop" stop "step" step))
  (define intervals (/ (- stop start) step))
  (define rounded (inexact->exact (round (exact->inexact intervals))))
  (unless (< (abs (- intervals rounded)) 1e-8)
    (raise-arguments-error
     who "angular step must land exactly on the stop angle"
     "start" start "stop" stop "step" step))
  (for/list ([index (in-range (add1 rounded))]) (+ start (* index step))))

(define (radiation-card theta-count phi-count theta-start phi-start
                        theta-step phi-step)
  (format "RP 0 ~a ~a 1000 ~a ~a ~a ~a 1000 0"
          theta-count phi-count
          (number-field 'nec2c theta-start "theta start")
          (number-field 'nec2c phi-start "phi start")
          (number-field 'nec2c theta-step "theta step")
          (number-field 'nec2c phi-step "phi step")))

(define (run-pattern cards expected-count model-path executable keep? timeout)
  (define-values (run report)
    (runner-keywords
     model-path executable keep? timeout cards
     (lambda (report)
       (define actual (length (parsed-nec2c-report-patterns report)))
       (unless (= actual expected-count)
         (error 'nec2c-pattern
                "expected ~a pattern samples but parsed ~a"
                expected-count actual)))))
  (define samples (map enrich-pattern (parsed-nec2c-report-patterns report)))
  (values run samples report))

(define (nec2c-azimuth-pattern
         #:frequency [frequency (model-frequency)]
         #:elevation [elevation 0]
         #:start [start 0]
         #:stop [stop 360]
         #:step [step 1]
         #:model-path [model-path #f]
         #:executable [executable #f]
         #:keep-artifacts? [keep? #f]
         #:timeout [timeout #f])
  (define grounded? (analysis-grounded? model-path))
  (unless (and (real? elevation) (<= -90 elevation 90))
    (raise-argument-error 'nec2c-azimuth-pattern "real in [-90,90]" elevation))
  (when (and grounded? (negative? elevation))
    (raise-argument-error
     'nec2c-azimuth-pattern
     "nonnegative elevation for a grounded model"
     elevation))
  (define angles (angular-sequence 'nec2c-azimuth-pattern start stop step))
  (define-values (run samples _report)
    (run-pattern
     (list "PT -1" (frequency-card frequency)
           (radiation-card 1 (length angles) (- 90 elevation) start 0 step))
     (length angles) model-path executable keep? timeout))
  (nec2c-pattern run 'azimuth elevation samples))

(define (approximately=? a b [epsilon 1e-6])
  (< (abs (- a b)) epsilon))

(define (normalize-degrees angle)
  (- angle (* 360 (floor (/ angle 360)))))

(define (sample-at samples theta phi)
  (for/first ([sample (in-list samples)]
              #:when (and (approximately=? theta (nec2c-pattern-sample-theta-deg sample))
                          (approximately=?
                           (normalize-degrees phi)
                           (normalize-degrees
                            (nec2c-pattern-sample-phi-deg sample)))))
    sample))

(define (elevation-angle->nec angle azimuth)
  (if (<= angle 90)
      (values (- 90 angle) azimuth)
      (values (- angle 90) (+ azimuth 180))))

(define (nec2c-elevation-pattern
         #:frequency [frequency (model-frequency)]
         #:azimuth [azimuth 0]
         #:start [requested-start #f]
         #:stop [requested-stop #f]
         #:step [step 1]
         #:model-path [model-path #f]
         #:executable [executable #f]
         #:keep-artifacts? [keep? #f]
         #:timeout [timeout #f])
  (define grounded? (analysis-grounded? model-path))
  (define start (or requested-start (if grounded? 0 -90)))
  (define stop (or requested-stop (if grounded? 180 270)))
  (unless (and (>= start -90) (<= stop 270))
    (raise-arguments-error
     'nec2c-elevation-pattern "angles must lie in [-90,270]"
     "start" start "stop" stop))
  (when (and grounded? (or (< start 0) (> stop 180)))
    (raise-arguments-error
     'nec2c-elevation-pattern
     "a grounded model can only sample the upper hemisphere"
     "start" start "stop" stop))
  (define angles (angular-sequence 'nec2c-elevation-pattern start stop step))
  ;; Ask NEC for both halves of the vertical plane, then put samples back in
  ;; the requested signed-elevation order.
  (define theta-values
    (angular-sequence 'nec2c-elevation-pattern
                      0 (if grounded? 90 180) step))
  (define-values (run raw-samples _report)
    (run-pattern
     (list "PT -1" (frequency-card frequency)
           (radiation-card (length theta-values) 2 0 azimuth step 180))
     (* 2 (length theta-values)) model-path executable keep? timeout))
  (define ordered
    (for/list ([angle (in-list angles)])
      (define-values (theta phi) (elevation-angle->nec angle azimuth))
      (or (sample-at raw-samples theta phi)
          (error 'nec2c-elevation-pattern
                 "missing pattern sample for elevation angle ~a" angle))))
  (nec2c-pattern run 'elevation azimuth ordered))

(define (nec2c-radiation-grid
         #:frequency [frequency (model-frequency)]
         #:theta-step [theta-step 5]
         #:phi-step [phi-step 5]
         #:model-path [model-path #f]
         #:executable [executable #f]
         #:keep-artifacts? [keep? #f]
         #:timeout [timeout #f])
  (define grounded? (analysis-grounded? model-path))
  (define theta-values
    (angular-sequence 'nec2c-radiation-grid
                      0 (if grounded? 90 180) theta-step))
  (define phi-values
    (angular-sequence 'nec2c-radiation-grid 0 (- 360 phi-step) phi-step))
  (define-values (run samples report)
    (run-pattern
     (list "PT 0" "PQ 0" (frequency-card frequency)
           (radiation-card (length theta-values) (length phi-values)
                           0 0 theta-step phi-step))
     (* (length theta-values) (length phi-values))
     model-path executable keep? timeout))
  (define grid (nec2c-pattern-grid run theta-values phi-values samples))
  (set-nec2c-pattern-grid-diagnostics!
   grid (enrich-diagnostics report frequency))
  grid)

(define (nec2c-segment-diagnostics
         [frequency (model-frequency)]
         #:model-path [model-path #f]
         #:executable [executable #f]
         #:keep-artifacts? [keep? #f]
         #:timeout [timeout #f])
  (unless (and (real? frequency) (> frequency 0))
    (raise-argument-error 'nec2c-segment-diagnostics "positive-real?" frequency))
  (define-values (_run report)
    (runner-keywords
     model-path executable keep? timeout
     (list "PT 0" "PQ 0" (frequency-card frequency) "XQ 0")
     (lambda (report)
       (unless (pair? (parsed-nec2c-report-currents report))
         (error 'nec2c-segment-diagnostics "NEC2C returned no segment currents"))
       (unless (pair? (parsed-nec2c-report-charges report))
         (error 'nec2c-segment-diagnostics "NEC2C returned no segment charge densities")))))
  (enrich-diagnostics report frequency))

(struct resolved-near-field-section
  (request plane normal-axis position u-axis v-axis u-values v-values
           x-origin y-origin z-origin x-count y-count z-count
           x-step y-step z-step)
  #:transparent)

(define (feed-point edge)
  (define start (vertex-point (wire-edge-start edge)))
  (define end (vertex-point (wire-edge-end edge)))
  (define fraction
    (case (wire-edge-feed-location edge)
      [(start) 0]
      [(center) 1/2]
      [else 1]))
  (point3 (+ (point3-x start) (* fraction (- (point3-x end) (point3-x start))))
          (+ (point3-y start) (* fraction (- (point3-y end) (point3-y start))))
          (+ (point3-z start) (* fraction (- (point3-z end) (point3-z start))))))

(define (model-feed-centroid)
  (define feeds (map feed-point (require-feeds 'nec2c-near-field-planes)))
  (define count (length feeds))
  (point3 (/ (apply + (map point3-x feeds)) count)
          (/ (apply + (map point3-y feeds)) count)
          (/ (apply + (map point3-z feeds)) count)))

(define (model-axis-bounds accessor)
  (define extrema
    (for*/list ([edge (in-list (model-edges))]
                [point (in-list (list (vertex-point (wire-edge-start edge))
                                      (vertex-point (wire-edge-end edge))))]
                [sign (in-list '(-1 1))])
      (+ (accessor point) (* sign (/ (wire-edge-diameter edge) 2)))))
  (values (apply min extrema) (apply max extrema)))

(define (axis-coordinate point axis)
  (case axis [(x) (point3-x point)] [(y) (point3-y point)] [(z) (point3-z point)]))

(define (axis-model-bounds axis)
  (model-axis-bounds
   (case axis [(x) point3-x] [(y) point3-y] [(z) point3-z])))

(define (axis-request-range request axis)
  (case axis
    [(x) (requested-near-field-section-x-range request)]
    [(y) (requested-near-field-section-y-range request)]
    [(z) (requested-near-field-section-z-range request)]))

(define (linear-values minimum maximum count)
  (define step (/ (- maximum minimum) (sub1 count)))
  (for/list ([index (in-range count)]) (+ minimum (* index step))))

(define (resolve-near-field-section request centroid wavelength)
  (define plane (requested-near-field-section-plane request))
  (define-values (normal u-axis v-axis)
    (case plane
      [(xy) (values 'z 'x 'y)]
      [(xz) (values 'y 'x 'z)]
      [(yz) (values 'x 'y 'z)]))
  (define position
    (or (requested-near-field-section-position request)
        (axis-coordinate centroid normal)))
  ;; The automatic square is centered on the feed centroid.  Its half-width
  ;; is at least one wavelength and large enough to leave one wavelength
  ;; beyond every geometrical extremum on both in-plane axes.
  (define automatic-half-width
    (for*/fold ([half-width wavelength])
               ([axis (in-list (list u-axis v-axis))]
                [bound-index (in-range 2)])
      (define-values (minimum maximum) (axis-model-bounds axis))
      (define bound (if (zero? bound-index) minimum maximum))
      (max half-width (+ (abs (- bound (axis-coordinate centroid axis))) wavelength))))
  (define (resolved-range axis)
    (or (axis-request-range request axis)
        (list (- (axis-coordinate centroid axis) automatic-half-width)
              (+ (axis-coordinate centroid axis) automatic-half-width))))
  (define u-range (resolved-range u-axis))
  (define v-range (resolved-range v-axis))
  (define counts (requested-near-field-section-samples request))
  (define u-count (first counts))
  (define v-count (second counts))
  (define u-values (linear-values (first u-range) (second u-range) u-count))
  (define v-values (linear-values (first v-range) (second v-range) v-count))
  (define origins (make-hash (list (cons normal position)
                                   (cons u-axis (first u-range))
                                   (cons v-axis (first v-range)))))
  (define axis-counts (make-hash (list (cons normal 1)
                                       (cons u-axis u-count)
                                       (cons v-axis v-count))))
  (define axis-steps (make-hash (list (cons normal 0)
                                      (cons u-axis (/ (- (second u-range) (first u-range))
                                                      (sub1 u-count)))
                                      (cons v-axis (/ (- (second v-range) (first v-range))
                                                      (sub1 v-count))))))
  (resolved-near-field-section
   request plane normal position u-axis v-axis u-values v-values
   (hash-ref origins 'x) (hash-ref origins 'y) (hash-ref origins 'z)
   (hash-ref axis-counts 'x) (hash-ref axis-counts 'y) (hash-ref axis-counts 'z)
   (hash-ref axis-steps 'x) (hash-ref axis-steps 'y) (hash-ref axis-steps 'z)))

(define (near-field-card quantity resolved)
  (format "~a 0 ~a ~a ~a ~a ~a ~a ~a ~a ~a"
          (if (eq? quantity 'electric) "NE" "NH")
          (resolved-near-field-section-x-count resolved)
          (resolved-near-field-section-y-count resolved)
          (resolved-near-field-section-z-count resolved)
          (number-field 'nec2c-near-field-planes
                        (resolved-near-field-section-x-origin resolved) "X origin")
          (number-field 'nec2c-near-field-planes
                        (resolved-near-field-section-y-origin resolved) "Y origin")
          (number-field 'nec2c-near-field-planes
                        (resolved-near-field-section-z-origin resolved) "Z origin")
          (number-field 'nec2c-near-field-planes
                        (resolved-near-field-section-x-step resolved) "X step")
          (number-field 'nec2c-near-field-planes
                        (resolved-near-field-section-y-step resolved) "Y step")
          (number-field 'nec2c-near-field-planes
                        (resolved-near-field-section-z-step resolved) "Z step")))

(define (grid-point resolved u-index v-index)
  (define coordinates
    (hash (resolved-near-field-section-normal-axis resolved)
          (resolved-near-field-section-position resolved)
          (resolved-near-field-section-u-axis resolved)
          (list-ref (resolved-near-field-section-u-values resolved) u-index)
          (resolved-near-field-section-v-axis resolved)
          (list-ref (resolved-near-field-section-v-values resolved) v-index)))
  (values (hash-ref coordinates 'x) (hash-ref coordinates 'y) (hash-ref coordinates 'z)))

(define (parsed-field-vector sample)
  (and sample
       (list (parsed-nec2c-near-field-x-component sample)
             (parsed-nec2c-near-field-y-component sample)
             (parsed-nec2c-near-field-z-component sample))))

(define (nec2c-near-field-planes
         #:frequency [frequency (model-frequency)]
         #:planes [planes #f]
         #:max-samples [max-samples 250000]
         #:model-path [model-path #f]
         #:executable [executable #f]
         #:keep-artifacts? [keep? #f]
         #:timeout [timeout #f])
  (unless (and (finite-real? frequency) (positive? frequency))
    (raise-argument-error 'nec2c-near-field-planes "positive-real?" frequency))
  (unless (exact-positive-integer? max-samples)
    (raise-argument-error 'nec2c-near-field-planes "exact-positive-integer?" max-samples))
  (define requests
    (or planes
        (list (near-field-section #:plane 'x)
              (near-field-section #:plane 'y)
              (near-field-section #:plane 'z))))
  (unless (and (list? requests) (pair? requests) (andmap near-field-section? requests))
    (raise-argument-error
     'nec2c-near-field-planes "a nonempty list of near-field-section values" requests))
  (define centroid (model-feed-centroid))
  (define resolved
    (for/list ([request (in-list requests)])
      (resolve-near-field-section request centroid (frequency->wavelength frequency))))
  (define requested-samples
    (for/sum ([section (in-list resolved)])
      (* (length (resolved-near-field-section-u-values section))
         (length (resolved-near-field-section-v-values section))
         (length (requested-near-field-section-fields
                  (resolved-near-field-section-request section))))))
  (when (> requested-samples max-samples)
    (raise-arguments-error
     'nec2c-near-field-planes "near-field request exceeds #:max-samples"
     "requested samples" requested-samples "maximum samples" max-samples))
  (define cards
    (append
     (list "PT 0" "PQ 0" (frequency-card frequency))
     (for*/list ([section (in-list resolved)]
                 [quantity (in-list
                            (requested-near-field-section-fields
                             (resolved-near-field-section-request section)))])
       (near-field-card quantity section))))
  (define-values (run report)
    (runner-keywords
     model-path executable keep? timeout cards
     (lambda (report)
       (define actual (length (parsed-nec2c-report-near-fields report)))
       (unless (= actual requested-samples)
         (error 'nec2c-near-field-planes
                "expected ~a near-field samples but parsed ~a"
                requested-samples actual)))))
  (define electric-remaining
    (filter (lambda (sample) (eq? 'electric (parsed-nec2c-near-field-quantity sample)))
            (parsed-nec2c-report-near-fields report)))
  (define magnetic-remaining
    (filter (lambda (sample) (eq? 'magnetic (parsed-nec2c-near-field-quantity sample)))
            (parsed-nec2c-report-near-fields report)))
  (define sections
    (for/list ([section (in-list resolved)])
      (define request (resolved-near-field-section-request section))
      (define count (* (length (resolved-near-field-section-u-values section))
                       (length (resolved-near-field-section-v-values section))))
      (define electric
        (and (memq 'electric (requested-near-field-section-fields request))
             (begin0 (take electric-remaining count)
               (set! electric-remaining (drop electric-remaining count)))))
      (define magnetic
        (and (memq 'magnetic (requested-near-field-section-fields request))
             (begin0 (take magnetic-remaining count)
               (set! magnetic-remaining (drop magnetic-remaining count)))))
      (define u-count (length (resolved-near-field-section-u-values section)))
      (define v-count (length (resolved-near-field-section-v-values section)))
      (define samples
        (for*/list ([v-index (in-range v-count)] [u-index (in-range u-count)])
          (define index (+ u-index (* v-index u-count)))
          (define-values (x y z) (grid-point section u-index v-index))
          (nec2c-near-field-sample
           x y z
           (parsed-field-vector (and electric (list-ref electric index)))
           (parsed-field-vector (and magnetic (list-ref magnetic index))))))
      (nec2c-near-field-section
       (resolved-near-field-section-plane section)
       (resolved-near-field-section-normal-axis section)
       (resolved-near-field-section-position section)
       (resolved-near-field-section-u-axis section)
       (resolved-near-field-section-v-axis section)
       (resolved-near-field-section-u-values section)
       (resolved-near-field-section-v-values section)
       samples
       (requested-near-field-section-fields request))))
  (nec2c-near-field-result run frequency sections (enrich-diagnostics report frequency)))

(define (mismatch-loss-db reflection-coefficient)
  (define accepted-fraction
    (- 1.0 (sqr (magnitude reflection-coefficient))))
  (if (positive? accepted-fraction)
      (* 10.0 (/ (log accepted-fraction) (log 10.0)))
      -inf.0))

(define (available-total-gain-samples samples)
  (filter
   (lambda (sample)
     (real? (nec2c-pattern-sample-total-gain-db sample)))
   samples))

(define (summarize-pattern who pattern reflection-coefficient)
  (define available
    (available-total-gain-samples (nec2c-pattern-grid-samples pattern)))
  (when (null? available)
    (raise-arguments-error who "a frequency has no available gain samples"
                           "frequency (MHz)"
                           (and (pair? (nec2c-pattern-grid-samples pattern))
                                (nec2c-pattern-sample-frequency-mhz
                                 (first
                                  (nec2c-pattern-grid-samples pattern))))))
  (define maximum-sample
    (argmax nec2c-pattern-sample-total-gain-db available))
  (define horizon-samples
    (filter
     (lambda (sample)
       (< (abs (nec2c-pattern-sample-elevation-deg sample)) 1e-6))
     available))
  (when (null? horizon-samples)
    (raise-arguments-error
     who
     "the angular grid does not contain the horizon (zero elevation)"))
  (define horizon-sample
    (argmax nec2c-pattern-sample-total-gain-db horizon-samples))
  (define maximum-gain
    (nec2c-pattern-sample-total-gain-db maximum-sample))
  (define horizon-gain
    (nec2c-pattern-sample-total-gain-db horizon-sample))
  (define mismatch-loss (mismatch-loss-db reflection-coefficient))
  (values maximum-gain
          (+ maximum-gain mismatch-loss)
          (list (normalize-degrees
                 (nec2c-pattern-sample-azimuth-deg maximum-sample))
                (nec2c-pattern-sample-elevation-deg maximum-sample))
          horizon-gain
          (+ horizon-gain mismatch-loss)))

(define (nec2c-gain-sweep
         start stop
         #:steps [steps #f]
         #:step [step #f]
         #:theta-step [theta-step 5]
         #:phi-step [phi-step 5]
         #:model-path [model-path #f]
         #:executable [executable #f]
         #:keep-artifacts? [keep? #f]
         #:timeout [timeout #f])
  (define who 'nec2c-gain-sweep)
  (define feed-count (length (feed-edges)))
  (unless (= feed-count 1)
    (raise-arguments-error
     who
     "maximum and realized gain sweeps currently require exactly one feed"
     "feeds" feed-count))
  (define-values (count increment)
    (sweep-count-and-increment who start stop steps step))
  (define grounded? (analysis-grounded? model-path))
  (define theta-values
    (angular-sequence who 0 (if grounded? 90 180) theta-step))
  (unless (ormap (lambda (theta) (approximately=? theta 90)) theta-values)
    (raise-arguments-error
     who
     "#:theta-step must place a sample on the horizon (theta = 90 degrees)"
     "theta step (degrees)" theta-step))
  (define phi-values
    (angular-sequence who 0 (- 360 phi-step) phi-step))
  (define angular-count (* (length theta-values) (length phi-values)))
  (define-values (run report)
    (runner-keywords
     model-path executable keep? timeout
     (list "PT -1" (frequency-card start count increment)
           (radiation-card (length theta-values) (length phi-values)
                           0 0 theta-step phi-step))
     (lambda (report)
       (define feed-rows (parsed-nec2c-report-feeds report))
       (define pattern-rows (parsed-nec2c-report-patterns report))
       (unless (= (length feed-rows) count)
         (error who "expected ~a feed measurements but parsed ~a"
                count (length feed-rows)))
       (unless (= (length pattern-rows) (* count angular-count))
         (error who "expected ~a pattern samples but parsed ~a"
                (* count angular-count) (length pattern-rows))))))
  (define feedpoints (map enrich-feed (parsed-nec2c-report-feeds report)))
  (define patterns (map enrich-pattern (parsed-nec2c-report-patterns report)))
  (define reference (model-impedance))
  (define samples
    (for/list ([feedpoint (in-list feedpoints)])
      (define frequency (nec2c-feedpoint-sample-frequency-mhz feedpoint))
      (define frequency-patterns
        (filter
         (lambda (sample)
           (approximately=?
            frequency (nec2c-pattern-sample-frequency-mhz sample)))
         patterns))
      (unless (= (length frequency-patterns) angular-count)
        (error who
               "frequency ~a MHz has ~a pattern samples; expected ~a"
               frequency (length frequency-patterns) angular-count))
      (define pattern
        (nec2c-pattern-grid run theta-values phi-values frequency-patterns))
      (define-values (reflection return-loss vswr)
        (reflection-metrics
         (nec2c-feedpoint-sample-impedance feedpoint) reference))
      (define-values
        (maximum-gain realized-maximum-gain maximum-direction
                      horizon-gain realized-horizon-gain)
        (summarize-pattern who pattern reflection))
      (nec2c-gain-sweep-sample
       frequency feedpoint reflection return-loss vswr pattern
       maximum-gain realized-maximum-gain maximum-direction
       horizon-gain realized-horizon-gain)))
  (nec2c-gain-sweep-result run reference samples))
