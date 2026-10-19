#lang racket

(require rackunit
         racket/file
         "../antenna-turtle/main.rkt")

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
  (model-frequency 150)
  (wire-on)
  (spread forward 1 feed center)
  (define destination (make-temporary-file "nec2c-report-~a.html" #f
                                           (current-directory)))
  (dynamic-wind
   void
   (lambda ()
     (write-nec2c-html-report sweep destination #:pattern pattern #:near-fields near-fields)
     (define html (file->string destination))
     (check-regexp-match #rx"antenna-turtle-report/nec2c-m1" html)
     (check-true (string-contains? html "Portable \\u003cYagi-shaped> fixture"))
     (check-false (regexp-match? #rx"Portable <Yagi-shaped> fixture" html))
     (check-regexp-match #rx"pattern_frequency_mhz" html)
     (check-regexp-match #rx"segment_samples" html)
     (check-regexp-match #rx"surface_current_samples" html)
     (check-regexp-match #rx"current_density" html)
     (check-regexp-match #rx"charge_density" html)
     (check-regexp-match #rx"power_budget" html)
     (check-regexp-match #rx"e_theta" html)
     (check-regexp-match #rx"near_fields" html)
     (check-regexp-match #rx"NEAR FIELD" html)
     (check-regexp-match #rx"instantaneous magnitude" html)
     (check-regexp-match #rx"instantaneous current" html)
     (check-regexp-match #rx"SMOOTH PATCH CURRENTS" html)
     (check-regexp-match #rx"port_samples" html)
     (check-regexp-match #rx"3D VIEW" html)
     (check-regexp-match #rx"2D PATTERN" html)
     (check-regexp-match #rx"PATTERN OPACITY" html)
     (check-regexp-match #rx"3 dB COLOR BANDS" html)
     (check-regexp-match #rx"SHOW SETTINGS" html)
     (check-regexp-match #rx"total reference" html)
     (check-regexp-match #rx"plot-hover-readout" html)
     (check-regexp-match #rx"axes-visible" html))
   (lambda () (when (file-exists? destination) (delete-file destination)))))

(test-case "generic HTML report entry point dispatches NEC2C without OpenEMS"
  (define destination (make-temporary-file "nec2c-generic-report-~a.html" #f
                                           (current-directory)))
  (dynamic-wind
   void
   (lambda ()
     (write-html-report sweep destination #:pattern pattern #:near-fields #f)
     (check-regexp-match #rx"antenna-turtle-report/nec2c-m1"
                         (file->string destination)))
   (lambda () (when (file-exists? destination) (delete-file destination)))))

(test-case "a plain NEC2C sweep requires an explicit radiation grid"
  (check-exn #rx"#:pattern"
             (lambda ()
               (write-nec2c-html-report sweep "unwritten.html"))))
