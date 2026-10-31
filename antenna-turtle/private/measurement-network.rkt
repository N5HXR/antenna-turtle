#lang racket/base

(require racket/list
         racket/math
         racket/runtime-path
         "core.rkt"
         "measurement-interpolation.rkt"
         "nec2c.rkt"
         "network.rkt")

(provide
 impedance-at admittance-at resistance-at reactance-at
 reflection-at s11-db-at return-loss-at vswr-at
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

(define (impedance-at result frequency #:port [port #f]
                      #:interpolate? [interpolate? #t])
  (cond
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
