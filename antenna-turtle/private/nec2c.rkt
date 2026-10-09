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
 (struct-out parsed-nec2c-feed)
 (struct-out parsed-nec2c-pattern)
 (struct-out parsed-nec2c-report)
 (struct-out exn:fail:nec2c)
 parse-nec2c-output
 nec2c-measure-impedance
 nec2c-vswr-sweep
 nec2c-sweep->network-sweep
 nec2c-azimuth-pattern
 nec2c-elevation-pattern
 nec2c-radiation-grid)

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
(struct nec2c-pattern-grid (run theta-values phi-values samples) #:transparent)

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
(struct parsed-nec2c-report (feeds patterns) #:transparent)

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

(define nec2c-executable
  (make-parameter
   #f
   (lambda (value)
     (unless (or (not value) (path-string? value))
       (raise-argument-error 'nec2c-executable "(or/c #f path-string?)" value))
     value)))

(define numeric-token-rx
  #px"^[+-]?(?:[0-9]+(?:[.][0-9]*)?|[.][0-9]+)(?:[Ee][+-]?[0-9]+)?$")

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
      [else
       (define tokens (string-split (string-trim line)))
       (define parsed
         (and frequency
              (case mode
                [(feeds) (parse-feed-row frequency tokens)]
                [(patterns) (parse-pattern-row frequency tokens)]
                [else #f])))
       (cond
         [parsed
          (set! rows-started? #t)
          (if (eq? mode 'feeds)
              (set! feeds (cons parsed feeds))
              (set! patterns (cons parsed patterns)))]
         [(and rows-started? (string=? (string-trim line) ""))
          (set! mode #f)
          (set! rows-started? #f)])]))
  (parsed-nec2c-report (reverse feeds) (reverse patterns)))

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

(define (run-command executable arguments stdout-path stderr-path timeout)
  (define started (current-inexact-milliseconds))
  (define environment (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! environment #"LC_ALL" #"C")
  (define-values (process timed-out?)
    (parameterize ([current-environment-variables environment])
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
      (run-command executable
                   (list (string-append "-i" (path->string input-path))
                         (string-append "-o" (path->string output-path)))
                   stdout-path stderr-path timeout))
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
                     (list (frequency-card frequency) "XQ 0")
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
                     (list (frequency-card start count increment) "XQ 0")
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
  (values run samples))

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
  (define-values (run samples)
    (run-pattern
     (list (frequency-card frequency)
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
  (define-values (run raw-samples)
    (run-pattern
     (list (frequency-card frequency)
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
  (define-values (run samples)
    (run-pattern
     (list (frequency-card frequency)
           (radiation-card (length theta-values) (length phi-values)
                           0 0 theta-step phi-step))
     (* (length theta-values) (length phi-values))
     model-path executable keep? timeout))
  (define expected (* (length theta-values) (length phi-values)))
  (nec2c-pattern-grid run theta-values phi-values samples))
