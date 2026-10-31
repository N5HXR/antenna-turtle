#lang racket

(require file/gunzip
         net/base64
         rackunit
         racket/file
         racket/port
         "../antenna-turtle/main.rkt")

(define (compressed-report-json html)
  (define match
    (regexp-match
     #px"<script type=\"application/gzip\" id=\"antenna-turtle-report-data-gzip\">([^<]+)</script>"
     html))
  (unless match
    (error 'compressed-report-json "report has no inline gzip payload"))
  (bytes->string/utf-8
   (call-with-output-bytes
    (lambda (out)
      (gunzip-through-ports
       (open-input-bytes
        (base64-decode (string->bytes/utf-8 (second match))))
       out)))))

(define run
  (nec2c-run-info "/usr/bin/nec2c" "test" 12 0 "" ""
                   (nec2c-artifacts #f #f #f #t #f)))

(define (feedpoint frequency impedance)
  (nec2c-feedpoint-sample
   'feed-1 frequency 1 11 1+0i (/ 1 impedance) impedance (/ 1 impedance) 0.5))

(define (sweep-sample frequency impedance)
  (define reflection (/ (- impedance 50) (+ impedance 50)))
  (define magnitude-value (magnitude reflection))
  (nec2c-sweep-sample
   (feedpoint frequency impedance)
   reflection
   (* -20 (/ (log (max magnitude-value 1e-12)) (log 10)))
   (/ (+ 1 magnitude-value) (- 1 magnitude-value))))

(define sweep
  (nec2c-sweep-result
   run 50
   (for/list ([frequency '(140 150 160)]
              [impedance '(35+12i 50+0i 68-15i)])
     (nec2c-sweep-frequency frequency
                            (list (sweep-sample frequency impedance))))))

(define theta-values '(0 90 180))
(define phi-values '(0 90 180 270))
(define pattern
  (nec2c-pattern-grid
   run theta-values phi-values
   (for*/list ([theta (in-list theta-values)]
               [phi (in-list phi-values)])
     (define gain (- 8 (* 0.08 (abs (- phi 90))) (* 0.03 (abs (- theta 90)))))
     (nec2c-pattern-sample
      150 theta phi (- 90 theta) phi
      (- gain 3) (- gain 6) gain 1 0 'linear 1+0i 0+0i))))

(define diagnostics
  (nec2c-diagnostics
   150
   (list (nec2c-segment-sample 150 1 1 0.1+0.02i 1e-12-2e-12i))
   (nec2c-power-budget 150 0.5 0.45 0.04 0.01 90)))
(set-nec2c-diagnostics-surface-currents!
 diagnostics
 (list
  (nec2c-surface-current-sample
   150 1 (point3 0 0 0)
   (list 0.003+0.001i 0.002-0.0005i 0.0+0.0i))))
(set-nec2c-diagnostics-volume-currents!
 diagnostics
 (list
  (nec2c-volume-current-sample
   150 1 1 1 1 (point3 0.5 0 0) (point3 0.1 0.1 0.1)
   (list 0.01+0.02i 0.0+0.0i 0.03-0.01i))))
(set-nec2c-pattern-grid-diagnostics! pattern diagnostics)

(define near-fields
  (nec2c-near-field-result
   run 150
   (list
    (nec2c-near-field-section
     'xy 'z 0 'x 'y '(-1 1) '(-1 1)
     (list
      (nec2c-near-field-sample -1 -1 0 '(1+0i 0+0i 0+0i) '(0+0i 0.01+0i 0+0i))
      (nec2c-near-field-sample 1 -1 0 '(0.8+0.2i 0+0i 0+0i) '(0+0i 0.008+0i 0+0i))
      (nec2c-near-field-sample -1 1 0 '(0.8-0.2i 0+0i 0+0i) '(0+0i 0.008+0i 0+0i))
      (nec2c-near-field-sample 1 1 0 '(1+0i 0+0i 0+0i) '(0+0i 0.01+0i 0+0i)))
     '(electric magnetic)))
   (nec2c-pattern-grid-diagnostics pattern)))

(test-case "NEC2C HTML report combines wire geometry, plots, and a radiation grid"
  (reset-model!)
  (model-title "Portable <Yagi-shaped> fixture")
  (model-frequency 150.123456789)
  (wire-on)
  (spread forward 1 feed center)
  (define report-dielectric (dielectric name report-foam er 3.5))
  (from-here
    (move right 0.5)
    (cuboid name report-volume size '(0.1 0.1 0.1)
            material report-dielectric anchor center))
  (define destination (make-temporary-file "nec2c-report-~a.html" #f
                                           (current-directory)))
  (dynamic-wind
   void
   (lambda ()
     (write-nec2c-html-report sweep destination #:pattern pattern #:near-fields near-fields)
     (define html (file->string destination))
     (define payload (compressed-report-json html))
     (define searchable (string-append html payload))
     (check-regexp-match #rx"antenna-turtle-report/nec2c-m1" payload)
     (check-regexp-match #rx"\"model_frequency_mhz\":150\\.12346" payload)
     (check-true (string-contains? payload "Portable <Yagi-shaped> fixture"))
     (check-false (regexp-match? #rx"Portable <Yagi-shaped> fixture" html))
     (check-regexp-match #rx"pattern_frequency_mhz" searchable)
     (check-regexp-match #rx"segment_samples" searchable)
     (check-regexp-match #rx"surface_current_samples" searchable)
     (check-regexp-match #rx"volume_current_samples" searchable)
     (check-regexp-match #rx"dielectric_volumes" searchable)
     (check-regexp-match #rx"dielectric J magnitude" searchable)
     (check-regexp-match #rx"current_density" searchable)
     (check-regexp-match #rx"charge_density" searchable)
     (check-regexp-match #rx"power_budget" searchable)
     (check-regexp-match #rx"e_theta" searchable)
     (check-regexp-match #rx"near_fields" searchable)
     (check-regexp-match #rx"NEAR FIELD" searchable)
     (check-regexp-match #rx"instantaneous magnitude" searchable)
     (check-regexp-match #rx"average power vectors" searchable)
     (check-regexp-match #rx"instantaneous power intensity" searchable)
     (check-regexp-match #rx"instantaneous power vectors" searchable)
     (check-regexp-match #rx"instantaneous current" searchable)
     (check-regexp-match #rx"SMOOTH PATCH CURRENTS" searchable)
     (check-regexp-match #rx"port_samples" searchable)
     (check-regexp-match #rx"3D VIEW" searchable)
     (check-regexp-match #rx"2D PATTERN" searchable)
     (check-regexp-match #rx"PATTERN OPACITY" searchable)
     (check-regexp-match #rx"3 dB COLOR BANDS" searchable)
     (check-regexp-match #rx"SHOW SETTINGS" searchable)
     (check-regexp-match #rx"total reference" searchable)
     (check-regexp-match #rx"plot-hover-readout" searchable)
     (check-regexp-match #rx"axes-visible" searchable))
   (lambda () (when (file-exists? destination) (delete-file destination)))))

(test-case "generic HTML report entry point dispatches NEC2C without OpenEMS"
  (define destination (make-temporary-file "nec2c-generic-report-~a.html" #f
                                           (current-directory)))
  (dynamic-wind
   void
   (lambda ()
     (write-html-report sweep destination #:pattern pattern #:near-fields #f)
     (check-regexp-match #rx"antenna-turtle-report/nec2c-m1"
                         (compressed-report-json (file->string destination))))
   (lambda () (when (file-exists? destination) (delete-file destination)))))

(test-case "NEC2C HTML report encodes unbounded network values as null"
  (define infinite-sweep
    (nec2c-sweep-result
     run 50
     (list
      (nec2c-sweep-frequency
       150
       (list
        (nec2c-sweep-sample
         (feedpoint 150 50+0i)
         0+0i
         +inf.0
         1.0))))))
  (define destination (make-temporary-file "nec2c-infinite-report-~a.html" #f
                                           (current-directory)))
  (dynamic-wind
   void
   (lambda ()
     (write-nec2c-html-report
      infinite-sweep destination #:pattern pattern #:near-fields #f)
     (define html (file->string destination))
     (check-regexp-match #rx"\"s11_db\":null" (compressed-report-json html)))
   (lambda () (when (file-exists? destination) (delete-file destination)))))

(test-case "NEC2C HTML report describes coax ports and resolved wire loads"
  (reset-model!)
  (model-frequency 150)
  (maximum-segment-length 0.1)
  (move up 1)
  (from-here (move forward 0.05) (with-wire (move forward 0.5)))
  (from-here (move back 0.05) (with-wire (move back 0.5)))
  (define output-port
    (wire-port forward name report-output gap 0.1 diameter 0.002))
  (coax name report-coax output output-port impedance 50 velocity-factor 0.66
        diameter 0.01 color "dark orange" input-gap 0.02
    (move down 0.2)
    (lumped-element down name report-choke inductance 1e-6
                    topology series gap 0.01)
    (move down 0.8))
  (define destination (make-temporary-file "nec2c-coax-report-~a.html" #f
                                           (current-directory)))
  (dynamic-wind
   void
   (lambda ()
     (write-nec2c-html-report sweep destination #:pattern pattern #:near-fields #f)
     (define payload (compressed-report-json (file->string destination)))
     (check-true (string-contains? payload "\"coaxes\":[{"))
     (check-true (string-contains? payload "\"ports\":[{"))
     (check-true (string-contains? payload "\"transmission_lines\":[{"))
     (check-true (string-contains? payload "\"lumped_loads\":[{"))
     (check-regexp-match #rx"report-choke" payload)
     (check-regexp-match #rx"coax-shield" payload))
   (lambda () (when (file-exists? destination) (delete-file destination)))))

(test-case "a plain NEC2C sweep requires an explicit radiation grid"
  (check-exn #rx"#:pattern"
             (lambda ()
               (write-nec2c-html-report sweep "unwritten.html"))))
