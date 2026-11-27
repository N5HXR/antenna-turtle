#lang racket/base

(require racket/list
         racket/math
         racket/runtime-path
         "core.rkt"
         "measurement-interpolation.rkt"
         "nec2c.rkt"
         "network.rkt"
         "wire-network.rkt")

(provide
 impedance-at admittance-at resistance-at reactance-at
 reflection-at s11-db-at return-loss-at vswr-at
 find-s11-minimum
 deembed-transmission-line
 impedance->reflection-coefficient
 reflection-coefficient->return-loss reflection-coefficient->vswr
 impedance->return-loss impedance->vswr
 return-loss->vswr vswr->return-loss
 s-parameter-at s-parameter-db-at s-parameter-phase-at
 measurement-network-frequencies measurement-network-ports
 characteristic-impedance-at )

;; Network measurements apply equally to NEC2C and OpenEMS data.  OpenEMS
;; itself needs the optional Manifold backend, however, so load its result
;; accessors only when an OpenEMS result is actually supplied.  Keeping this
;; module independent means ordinary wire-model measurements and conversion
;; helpers remain part of the Windows language.
(define-runtime-path openems-path "openems.rkt")
(define optional-openems-bindings (make-hasheq))

(define (optional-openems-binding name)
  (hash-ref!
   optional-openems-bindings name
   (lambda ()
     (with-handlers ([exn:fail? (lambda (_) #f)])
       (dynamic-require openems-path name)))))

(define (openems-predicate? name value)
  (define predicate (optional-openems-binding name))
  (and predicate (predicate value)))

(define (openems-accessor who name . values)
  (define accessor (optional-openems-binding name))
  (unless accessor
    (raise-user-error
     who
     "OpenEMS measurements require the optional Manifold dependency"))
  (apply accessor values))

(define (name=? left right)
  (or (equal? left right)
      (string=? (format "~a" left) (format "~a" right))))

(define (unique-names names) (remove-duplicates names name=?))
(define (unique-sorted numbers)
  (sort (remove-duplicates numbers approximately=?) <))

(define (network-result->sweep who result)
  (cond
    [(network-sweep? result) result]
    [(nec2c-sweep-result? result) (nec2c-sweep->network-sweep result)]
    [(nec2c-gain-sweep-result? result)
     (nec2c-gain-sweep->network-sweep result)]
    [(openems-predicate? 'openems-sweep-result? result)
     (openems-accessor who 'openems-sweep->network-sweep result)]
    [(openems-predicate? 'openems-multiport-result? result)
     (openems-accessor who 'openems-sweep->network-sweep result)]
    [else
     (raise-argument-error
      who
      (string-append
       "network-sweep?, nec2c-sweep-result?, nec2c-gain-sweep-result?, "
       "openems-sweep-result?, or openems-multiport-result?")
      result)]))

(define (deembedding-name who value)
  (cond [(string? value) value]
        [(symbol? value) (symbol->string value)]
        [else (raise-argument-error who "(or/c symbol? string?)" value)]))

(define (find-transmission-line who requested-name)
  (define name (deembedding-name who requested-name))
  (define matching
    (filter (lambda (line)
              (string=? name (format "~a" (wire-transmission-line-name line))))
            (model-wire-transmission-lines)))
  (if (pair? matching)
      (car matching)
      (raise-arguments-error
       who "no transmission line with that name exists in the current model"
       "line" requested-name
       "available lines" (map wire-transmission-line-name
                              (model-wire-transmission-lines)))))

(define (finite-complex? value)
  (and (number? value)
       (rational? (real-part value))
       (rational? (imag-part value))))

(define (network-sample-from-impedance port frequency impedance reference-impedance)
  (define reflection
    (/ (- impedance reference-impedance)
       (+ impedance reference-impedance)))
  (define magnitude* (magnitude reflection))
  (network-sample
   port frequency reflection impedance
   (if (zero? magnitude*)
       -inf.0
       (* 20.0 (/ (log magnitude*) (log 10.0))))
   (reflection-magnitude->vswr magnitude*)))

;; Reverse a lossless TL transformation.  The original sweep retains the
;; source-plane answer; this copy reports the antenna-side port instead.
(define (deembed-transmission-line result line-name #:feed [requested-feed #f])
  (define who 'deembed-transmission-line)
  (define sweep (network-result->sweep who result))
  (define line (find-transmission-line who line-name))
  (define feed-name
    (if requested-feed
        (deembedding-name who requested-feed)
        (format "~a" (wire-transmission-line-name line))))
  (define samples (network-sweep-samples sweep))
  (unless (for/or ([sample (in-list samples)])
            (string=? feed-name (format "~a" (network-sample-port-name sample))))
    (raise-arguments-error
     who "the selected transmission line has no matching feed in the sweep"
     "line" line-name "feed" feed-name
     "available feeds" (remove-duplicates (map network-sample-port-name samples))))
  (define z0 (wire-transmission-line-impedance line))
  (define physical-length (wire-transmission-line-physical-length line))
  (define velocity-factor (wire-transmission-line-velocity-factor line))
  (define output-name
    (format "~a" (wire-port-declaration-name
                    (wire-transmission-line-output-port line))))
  (define reference-impedance (network-sweep-reference-impedance sweep))
  (struct-copy
   network-sweep sweep
   [samples
    (for/list ([sample (in-list samples)])
      (if (string=? feed-name (format "~a" (network-sample-port-name sample)))
          (let* ([frequency (network-sample-frequency-mhz sample)]
                 [theta (* 2.0 pi
                           (/ physical-length
                              (* velocity-factor
                                 (frequency->wavelength frequency))))]
                 [tangent (tan theta)]
                 [input-impedance (network-sample-impedance sample)]
                 [output-impedance
                  (/ (* z0 (- input-impedance (* 0+1i z0 tangent)))
                     (- z0 (* 0+1i input-impedance tangent)))])
            (unless (finite-complex? output-impedance)
              (raise-arguments-error
               who "de-embedding produced a non-finite antenna-side impedance"
               "frequency (MHz)" frequency "line" line-name))
            (network-sample-from-impedance output-name frequency output-impedance
                                           reference-impedance))
          sample))]))

(define (select-name who requested available description)
  (define names (unique-names available))
  (cond
    [requested
     (or (findf (lambda (name) (name=? name requested)) names)
         (raise-arguments-error who (format "unknown ~a" description)
                                "requested" requested "available" names))]
    [(= (length names) 1) (first names)]
    [else
     (raise-arguments-error
      who (format "the result has multiple ~as; select one by name" description)
      "available" names)]))

(define (network-samples-for who result port)
  (define samples (network-sweep-samples (network-result->sweep who result)))
  (define selected
    (select-name who port (map network-sample-port-name samples) "port"))
  (filter (lambda (sample)
            (name=? (network-sample-port-name sample) selected))
          samples))

(define (network-value-at who result frequency port interpolate? accessor)
  (sample-at-frequency
   who (network-samples-for who result port) frequency
   network-sample-frequency-mhz accessor interpolate-complex interpolate?))

(struct aggregate-impedance-sample (frequency-mhz impedance) #:transparent)

(define (nec2c-feedpoint-groups who result)
  (cond
    [(nec2c-impedance-result? result)
     (define samples (nec2c-impedance-result-samples result))
     (for/list ([frequency
                (in-list
                 (unique-sorted
                  (map nec2c-feedpoint-sample-frequency-mhz samples)))])
       (cons frequency
             (filter
              (lambda (sample)
                (approximately=?
                 frequency (nec2c-feedpoint-sample-frequency-mhz sample)))
              samples)))]
    [(nec2c-sweep-result? result)
     (for/list ([frequency
                (in-list (nec2c-sweep-result-frequencies result))])
       (cons
        (nec2c-sweep-frequency-frequency-mhz frequency)
        (map nec2c-sweep-sample-feedpoint
             (nec2c-sweep-frequency-feed-samples frequency))))]
    [else
     (raise-arguments-error
      who
      "parallel port aggregation requires a native NEC2C impedance or VSWR sweep result"
      "result" result)]))

(define (complex-approximately=? left right [relative-tolerance 1e-9])
  (<= (magnitude (- left right))
      (* relative-tolerance
         (max 1.0 (magnitude left) (magnitude right)))))

(define (select-aggregate-ports who requested available)
  (define names (unique-names available))
  (cond
    [(eq? requested 'all) names]
    [(not (list? requested))
     (raise-argument-error who "(or/c 'all (non-empty-listof port-name))"
                           requested)]
    [(null? requested)
     (raise-argument-error who "(or/c 'all (non-empty-listof port-name))"
                           requested)]
    [else
     (define selected
       (for/list ([name (in-list requested)])
         (or (findf (lambda (available-name) (name=? available-name name)) names)
             (raise-arguments-error who "unknown port in aggregate selection"
                                    "requested" name "available" names))))
     (unless (= (length selected) (length (unique-names selected)))
       (raise-arguments-error
        who "aggregate port selection contains a duplicate"
        "ports" requested))
     selected]))

(define (parallel-impedance-samples result requested-ports combine)
  (define who 'impedance-at)
  (unless (eq? combine 'parallel)
    (raise-argument-error who "'parallel" combine))
  (define groups (nec2c-feedpoint-groups who result))
  (when (null? groups)
    (raise-arguments-error who "the result contains no feedpoint samples"))
  (define selected-names
    (select-aggregate-ports
     who requested-ports
     (append-map
      (lambda (group)
        (map nec2c-feedpoint-sample-feed-name (cdr group)))
      groups)))
  (for/list ([group (in-list groups)])
    (define frequency (car group))
    (define samples
      (for/list ([name (in-list selected-names)])
        (or (findf (lambda (sample)
                     (name=? name
                             (nec2c-feedpoint-sample-feed-name sample)))
                   (cdr group))
            (raise-arguments-error
             who "an aggregate port is missing at a sampled frequency"
             "port" name "frequency (MHz)" frequency))))
    (define voltage (nec2c-feedpoint-sample-voltage (first samples)))
    (for ([sample (in-list (rest samples))])
      (unless (complex-approximately=?
               voltage (nec2c-feedpoint-sample-voltage sample))
        (raise-arguments-error
         who
         "parallel aggregation requires equal complex source voltages and polarity"
         "frequency (MHz)" frequency
         "ports" selected-names
         "voltages" (map nec2c-feedpoint-sample-voltage samples))))
    (define total-current
      (for/sum ([sample (in-list samples)])
        (nec2c-feedpoint-sample-current sample)))
    (when (zero? total-current)
      (raise-arguments-error
       who "aggregate feed current is zero; parallel impedance is undefined"
       "frequency (MHz)" frequency "ports" selected-names))
    (aggregate-impedance-sample frequency (/ voltage total-current))))

(define (impedance-at result frequency #:port [port #f]
                      #:ports [ports #f]
                      #:combine [combine #f]
                      #:interpolate? [interpolate? #t])
  (when (and port (or ports combine))
    (raise-arguments-error
     'impedance-at
     "#:port is mutually exclusive with aggregate #:ports or #:combine"
     "port" port "ports" ports "combine" combine))
  (cond
    [(or ports combine)
     (sample-at-frequency
      'impedance-at
      (parallel-impedance-samples result (or ports 'all)
                                  (or combine 'parallel))
      frequency aggregate-impedance-sample-frequency-mhz
      aggregate-impedance-sample-impedance interpolate-complex interpolate?)]
    [(nec2c-impedance-result? result)
     (define samples (nec2c-impedance-result-samples result))
     (define selected
       (select-name 'impedance-at port
                    (map nec2c-feedpoint-sample-feed-name samples) "port"))
     (sample-at-frequency
      'impedance-at
      (filter (lambda (sample)
                (name=? (nec2c-feedpoint-sample-feed-name sample) selected))
              samples)
      frequency nec2c-feedpoint-sample-frequency-mhz
      nec2c-feedpoint-sample-impedance interpolate-complex interpolate?)]
    [else
     (network-value-at 'impedance-at result frequency port interpolate?
                       network-sample-impedance)]))

(define (admittance-at result frequency #:port [port #f]
                       #:interpolate? [interpolate? #t])
  (/ 1 (impedance-at result frequency #:port port #:interpolate? interpolate?)))

(define (resistance-at result frequency #:port [port #f]
                       #:interpolate? [interpolate? #t])
  (real-part
   (impedance-at result frequency #:port port #:interpolate? interpolate?)))

(define (reactance-at result frequency #:port [port #f]
                      #:interpolate? [interpolate? #t])
  (imag-part
   (impedance-at result frequency #:port port #:interpolate? interpolate?)))

(define (reflection-at result frequency #:port [port #f]
                       #:interpolate? [interpolate? #t])
  (network-value-at 'reflection-at result frequency port interpolate?
                    network-sample-reflection-coefficient))

(define (magnitude->db magnitude*)
  (if (zero? magnitude*) -inf.0 (* 20.0 (/ (log magnitude*) (log 10.0)))))

(define (s11-db-at result frequency #:port [port #f]
                   #:interpolate? [interpolate? #t])
  (magnitude->db
   (magnitude
    (reflection-at result frequency #:port port #:interpolate? interpolate?))))

(define (find-s11-minimum result #:port [port #f])
  (define samples (network-samples-for 'find-s11-minimum result port))
  (when (null? samples)
    (raise-arguments-error
     'find-s11-minimum "the selected port has no network samples"))
  (define sample (argmin network-sample-s11-db samples))
  (list (network-sample-frequency-mhz sample)
        (network-sample-s11-db sample)))

(define (return-loss-at result frequency #:port [port #f]
                        #:interpolate? [interpolate? #t])
  (- (s11-db-at result frequency #:port port #:interpolate? interpolate?)))

(define (vswr-at result frequency #:port [port #f]
                 #:interpolate? [interpolate? #t])
  (reflection-magnitude->vswr
   (magnitude
    (reflection-at result frequency #:port port #:interpolate? interpolate?))))

(define (positive-system-impedance who value)
  (unless (and (real? value) (rational? value) (positive? value))
    (raise-argument-error who "positive finite real system impedance" value))
  value)

(define (impedance->reflection-coefficient
         impedance [system-impedance (model-impedance)])
  (unless (number? impedance)
    (raise-argument-error 'impedance->reflection-coefficient "number?" impedance))
  (define z0
    (positive-system-impedance
     'impedance->reflection-coefficient system-impedance))
  (/ (- impedance z0) (+ impedance z0)))

(define (reflection-coefficient->return-loss reflection-coefficient)
  (unless (number? reflection-coefficient)
    (raise-argument-error
     'reflection-coefficient->return-loss "number?" reflection-coefficient))
  (- (magnitude->db (magnitude reflection-coefficient))))

(define (reflection-coefficient->vswr reflection-coefficient)
  (unless (number? reflection-coefficient)
    (raise-argument-error
     'reflection-coefficient->vswr "number?" reflection-coefficient))
  (reflection-magnitude->vswr (magnitude reflection-coefficient)))

(define (impedance->return-loss
         impedance [system-impedance (model-impedance)])
  (reflection-coefficient->return-loss
   (impedance->reflection-coefficient impedance system-impedance)))

(define (impedance->vswr impedance [system-impedance (model-impedance)])
  (reflection-coefficient->vswr
   (impedance->reflection-coefficient impedance system-impedance)))

(define (return-loss->vswr return-loss-db)
  (unless (real? return-loss-db)
    (raise-argument-error 'return-loss->vswr "real?" return-loss-db))
  (reflection-magnitude->vswr (expt 10.0 (/ (- return-loss-db) 20.0))))

(define (vswr->return-loss vswr)
  (unless (and (real? vswr) (>= vswr 1))
    (raise-argument-error 'vswr->return-loss "real >= 1" vswr))
  (cond
    [(= vswr 1) +inf.0]
    [(infinite? vswr) 0.0]
    [else
     (reflection-coefficient->return-loss (/ (- vswr 1) (+ vswr 1)))]))

(define (multiport-samples who result from to)
  (unless (openems-predicate? 'openems-multiport-result? result)
    (raise-argument-error who "openems-multiport-result?" result))
  (define names
    (map (lambda (port) (openems-accessor who 'openems-result-port-name port))
         (openems-accessor who 'openems-multiport-result-ports result)))
  (define selected-from (select-name who from names "input port"))
  (define selected-to
    (if to (select-name who to names "output port") selected-from))
  (filter
   (lambda (sample)
     (and (name=? (openems-accessor who 'openems-s-parameter-sample-input-port sample)
                  selected-from)
          (name=? (openems-accessor who 'openems-s-parameter-sample-output-port sample)
                  selected-to)))
   (openems-accessor who 'openems-multiport-result-s-parameters result)))

(define (s-parameter-at result frequency #:from [from #f] #:to [to #f]
                        #:interpolate? [interpolate? #t])
  (sample-at-frequency
   's-parameter-at (multiport-samples 's-parameter-at result from to) frequency
   (lambda (sample)
     (openems-accessor 's-parameter-at
                       'openems-s-parameter-sample-frequency-mhz sample))
   (lambda (sample)
     (openems-accessor 's-parameter-at
                       'openems-s-parameter-sample-value sample))
   interpolate-complex interpolate?))

(define (s-parameter-db-at result frequency #:from [from #f] #:to [to #f]
                           #:interpolate? [interpolate? #t])
  (magnitude->db
   (magnitude
    (s-parameter-at result frequency #:from from #:to to
                    #:interpolate? interpolate?))))

(define (s-parameter-phase-at result frequency #:from [from #f] #:to [to #f]
                              #:interpolate? [interpolate? #t])
  (* (angle (s-parameter-at result frequency #:from from #:to to
                            #:interpolate? interpolate?))
     (/ 180.0 pi)))

(define (measurement-network-frequencies result)
  (cond
    [(nec2c-impedance-result? result)
     (unique-sorted
      (map nec2c-feedpoint-sample-frequency-mhz
           (nec2c-impedance-result-samples result)))]
    [(nec2c-gain-sweep-result? result)
     (list
      (nec2c-feedpoint-sample-feed-name
       (nec2c-gain-sweep-sample-feedpoint
        (first (nec2c-gain-sweep-result-samples result)))))]
    [(openems-predicate? 'openems-multiport-result? result)
     (unique-sorted
      (map (lambda (sample)
             (openems-accessor 'measurement-frequencies
                               'openems-s-parameter-sample-frequency-mhz sample))
           (openems-accessor 'measurement-frequencies
                             'openems-multiport-result-s-parameters result)))]
    [else
     (unique-sorted
      (map network-sample-frequency-mhz
           (network-sweep-samples
            (network-result->sweep 'measurement-frequencies result))))]))

(define (measurement-network-ports result)
  (cond
    [(nec2c-impedance-result? result)
     (unique-names
      (map nec2c-feedpoint-sample-feed-name
           (nec2c-impedance-result-samples result)))]
    [(openems-predicate? 'openems-sweep-result? result)
     (list (openems-accessor 'measurement-ports
                             'openems-sweep-result-port-name result))]
    [(openems-predicate? 'openems-multiport-result? result)
     (map (lambda (port)
            (openems-accessor 'measurement-ports 'openems-result-port-name port))
          (openems-accessor 'measurement-ports
                            'openems-multiport-result-ports result))]
    [else
     (unique-names
      (map network-sample-port-name
           (network-sweep-samples
            (network-result->sweep 'measurement-ports result))))]))

(define (characteristic-impedance-at
         sweep frequency
         #:input  [input 'input]
         #:output [output 'output]
         #:zref   [zref 50]
         #:interpolate? [interpolate? #t])

  (define (s from to)
    (s-parameter-at sweep frequency
                    #:from from
                    #:to to
                    #:interpolate? interpolate?))

  (define s11 (s input input))
  (define s21 (s input output))
  (define s12 (s output input))
  (define s22 (s output output))

  (define numerator
    (- (* (+ 1 s11) (+ 1 s22))
       (* s12 s21)))

  (define denominator
    (- (* (- 1 s11) (- 1 s22))
       (* s12 s21)))

  (* zref (sqrt (/ numerator denominator))))
