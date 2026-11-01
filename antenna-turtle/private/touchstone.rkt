#lang racket/base

(require racket/list
         racket/port
         "core.rkt"
         "network.rkt"
         "nec2c.rkt")

(provide write-s1p)

(define (positive-finite-real? value)
  (and (real? value) (rational? value) (positive? value)))

(define (finite-complex? value)
  (and (number? value)
       (rational? (real-part value))
       (rational? (imag-part value))))

(define (feed-name->string value)
  (cond [(string? value) value]
        [(symbol? value) (symbol->string value)]
        [else value]))

(define (sweep->network-sweep who sweep)
  (cond [(network-sweep? sweep) sweep]
        [(nec2c-sweep-result? sweep) (nec2c-sweep->network-sweep sweep)]
        [else
         (raise-argument-error who
                               "(or/c network-sweep? nec2c-sweep-result?)"
                               sweep)]))

(define (select-feed-samples who samples requested-feed)
  (define names (remove-duplicates (map network-sample-port-name samples)))
  (define selected-name
    (cond [requested-feed
           (define normalized (feed-name->string requested-feed))
           (unless (member normalized names)
             (raise-arguments-error who "requested feed is absent from the sweep"
                                    "feed" requested-feed
                                    "available feeds" names))
           normalized]
          [(null? names)
           (raise-arguments-error who "sweep contains no network samples")]
          [(null? (cdr names)) (car names)]
          [else
           (raise-arguments-error
            who "sweep contains multiple feeds; supply #:feed"
            "available feeds" names)]))
  (values selected-name
          (sort (filter (lambda (sample)
                          (equal? (network-sample-port-name sample) selected-name))
                        samples)
                < #:key network-sample-frequency-mhz)))

(define (touchstone-number value)
  ;; A decimal datum is accepted by the broadly compatible Touchstone 1.x
  ;; readers; exact Racket rationals (such as 7/2) are not.
  (real->decimal-string (exact->inexact value) 12))

(define (write-s1p destination sweep
                   #:reference-impedance [reference-impedance (model-impedance)]
                   #:feed [feed #f])
  "Write a one-port Touchstone S-parameter file from a network sweep.

DESTINATION is an output port, path, or path string.  SWEEP may be a generic
network-sweep or the result of nec2c-vswr-sweep.  The selected feed defaults
to the only feed in the sweep; use #:feed for a multi-feed sweep."
  (define who 'write-s1p)
  (unless (positive-finite-real? reference-impedance)
    (raise-argument-error who "positive finite real reference impedance"
                          reference-impedance))
  (define network (sweep->network-sweep who sweep))
  (define-values (feed-name samples)
    (select-feed-samples who (network-sweep-samples network) feed))
  (for ([sample (in-list samples)])
    (unless (positive-finite-real? (network-sample-frequency-mhz sample))
      (raise-arguments-error who "positive finite sample frequency in MHz"
                             "sample" sample))
    (unless (finite-complex? (network-sample-impedance sample))
      (raise-arguments-error who "finite complex sample impedance"
                             "sample" sample)))
  (define (write output)
    (fprintf output "! Antenna Turtle one-port network\n")
    (fprintf output "! Model: ~a\n" (model-title))
    (fprintf output "! Feed: ~a\n" feed-name)
    (fprintf output "# MHz S RI R ~a\n" (touchstone-number reference-impedance))
    (for ([sample (in-list samples)])
      (define impedance (network-sample-impedance sample))
      (define gamma
        (/ (- impedance reference-impedance)
           (+ impedance reference-impedance)))
      (fprintf output "~a ~a ~a\n"
               (touchstone-number (network-sample-frequency-mhz sample))
               (touchstone-number (real-part gamma))
               (touchstone-number (imag-part gamma)))))
  (cond [(output-port? destination) (write destination)]
        [(or (path? destination) (string? destination))
         (call-with-output-file destination write #:exists 'replace)]
        [else
         (raise-argument-error who "(or/c output-port? path? path-string?)"
                               destination)]))
