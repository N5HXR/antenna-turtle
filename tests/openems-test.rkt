#lang racket

(require rackunit
         racket/file
         "../antenna-turtle/main.rkt"
         "../antenna-turtle/private/network.rkt"
         "../antenna-turtle/private/nec2c-view.rkt")

(test-case "OpenEMS port CSV parsing retains complex network values"
  (define path (make-temporary-file "antenna-turtle-openems-results~a.csv"))
  (dynamic-wind
    (lambda ()
      (call-with-output-file path
        #:exists 'truncate/replace
        (lambda (out)
          (displayln "900000000,0.1,-0.2,45.0,3.5,-13.0102999566398" out)
          (displayln "910000000,0.05,0,50.0,0,-26.0205999132796" out))))
    (lambda ()
      (define samples (parse-openems-port-results path))
      (check-equal? (length samples) 2)
      (define first-sample (first samples))
      (check-= (openems-port-sample-frequency-mhz first-sample) 900 1e-12)
      (check-equal? (openems-port-sample-reflection-coefficient first-sample)
                    0.1-0.2i)
      (check-equal? (openems-port-sample-impedance first-sample) 45.0+3.5i)
      (check-equal? (openems-port-sample-s11-db first-sample)
                    -13.0102999566398))
    (lambda () (when (file-exists? path) (delete-file path)))))

(test-case "OpenEMS NF2FF parsing restores user coordinates and field gain"
  (define path (make-temporary-file "antenna-turtle-openems-nf2ff~a.csv"))
  (dynamic-wind
    (lambda ()
      (call-with-output-file path
        #:exists 'truncate/replace
        (lambda (out)
          ;; A solver +Z sample with a unit theta-polarized field.
          (displayln "0,0,1,0,0,0" out))))
    (lambda ()
      ;; Rotate solver +Z onto user +X.
      (define transform
        '((0 0 1 0)
          (0 1 0 0)
          (-1 0 0 0)))
      (define grid
        (parse-openems-nf2ff-results path 915 2.0 0.5 transform #f))
      (define sample (first (nec2c-pattern-grid-samples grid)))
      (check-= (nec2c-pattern-sample-total-gain-db sample)
               (* 10 (/ (log 2) (log 10)))
               1e-10)
      (define direction (nec2c-pattern-sample-direction sample))
      (check-= (vector-ref direction 0) 1.0 1e-12)
      (check-= (vector-ref direction 1) 0.0 1e-12)
      (check-= (vector-ref direction 2) 0.0 1e-12)
      (check-= (nec2c-pattern-sample-elevation-deg sample) 0.0 1e-12)
      (check-= (nec2c-pattern-sample-azimuth-deg sample) 0.0 1e-12)
      (check-not-false (pair? (radiation-grid-renderers grid #:mesh-step 30))))
    (lambda () (when (file-exists? path) (delete-file path)))))

(test-case "OpenEMS rejects incomplete proof-of-concept scenes before launch"
  (reset-model!)
  (check-exn exn:fail:contract?
             (lambda ()
               (openems-sweep 800 1000 #:cells-per-wavelength 0)))
  (check-exn exn:fail:contract?
             (lambda ()
               (openems-sweep 800 1000 #:mesh-grading 1)))
  (check-exn exn:fail:contract?
             (lambda ()
               (openems-sweep 800 1000 #:end-criteria 1)))
  (check-exn exn:fail:contract?
             (lambda ()
               (openems-sweep 800 1000 #:progress? 'sometimes)))
  (check-exn #rx"no volume bodies"
             (lambda () (openems-sweep 800 1000)))

  (reset-model!)
  (port up)
  (check-exn #rx"no volume bodies"
             (lambda () (openems-sweep 800 1000))))

(test-case "OpenEMS artifacts can be explicitly released"
  (define directory
    (make-temporary-file "antenna-turtle-openems-close~a" 'directory))
  (define artifacts
    (openems-artifacts directory
                       (build-path directory "run-openems.m")
                       (build-path directory "simulation")
                       (build-path directory "simulation-manifest.rktd")
                       #t #t))
  (openems-close! artifacts)
  (check-false (directory-exists? directory))
  (check-false (openems-artifacts-available? artifacts))
  (check-not-exn (lambda () (openems-close! artifacts))))

(test-case "OpenEMS sweeps feed the existing network plot layer"
  (define run
    (openems-run-info #f 1 0 "" "" #f (hash)))
  (define result
    (openems-sweep-result
     run "feed" 50
     (list
      (openems-port-sample 900 0.1-0.2i 45+3.5i
                           (* 20 (log (magnitude 0.1-0.2i) 10)))
      (openems-port-sample 910 0.05 50
                           (* 20 (log 0.05 10))))))
  (define normalized (openems-sweep->network-sweep result))
  (check-equal? (network-sweep-reference-impedance normalized) 50)
  (check-equal? (length (network-sweep-samples normalized)) 2)
  (check-not-false (pair? (vswr-sweep-renderers result)))
  (check-not-false (pair? (return-loss-sweep-renderers result)))
  (check-not-false (pair? (impedance-sweep-renderers result)))
  (check-not-false (pair? (smith-chart-renderers result))))
