#lang racket

(require rackunit
         racket/file
         racket/path
         (only-in plot/no-gui plot-bitmap plot3d-bitmap)
         (only-in plot/utils plot-element-bounds-rect ivl-min ivl-max)
         (only-in "../antenna-turtle/private/visualization-handle.rkt"
                  make-visualization-handle)
         (only-in "../antenna-turtle/private/plot-cursor.rkt"
                  cursor-series
                  cursor-selection-series
                  cursor-selection-point
                  plot-legend-item
                  plot-legend-item-label
                  plot-legend-item-color
                  plot-legend-item-style
                  plot-legend-item-kind
                  nearest-cursor-sample)
         "../antenna-turtle/main.rkt")

(define parser-fixture
  #<<REPORT
                               --------- FREQUENCY --------
                                FREQUENCY : 3.0000E+02 MHz

                        --------- ANTENNA INPUT PARAMETERS ---------
  TAG   SEG       VOLTAGE (VOLTS)         CURRENT (AMPS)         IMPEDANCE (OHMS)        ADMITTANCE (MHOS)     POWER
  No:   No:     REAL      IMAGINARY     REAL      IMAGINARY     REAL      IMAGINARY    REAL       IMAGINARY   (WATTS)
    1    11  1.0000E+00  0.0000E+00  1.0000E-02  0.0000E+00  1.0000E+02  0.0000E+00  1.0000E-02  0.0000E+00  5.0000E-03
    2    32  0.0000E+00  1.0000E+00  0.0000E+00  2.0000E-02  5.0000E+01  0.0000E+00  2.0000E-02  0.0000E+00  1.0000E-02

                             ---------- RADIATION PATTERNS -----------
 ---- ANGLES -----     ----- POWER GAINS -----       ---- POLARIZATION ----   ---- E(THETA) ----    ----- E(PHI) ------
    0.00      0.00     -0.83    -0.83     2.18      1.0000     45.00 LEFT    6.6483E-04   -90.00  6.6483E-04      0.00
   90.00      0.00   -999.99  -999.99  -999.99      0.0000      0.00         0.0000E+00     0.00  0.0000E+00      0.00
REPORT
  )

(test-case "radiation cases are transparent named grid containers"
  (define case (radiation-case "comparison title" 'grid-placeholder))
  (check-true (radiation-case? case))
  (check-equal? (radiation-case-title case) "comparison title")
  (check-equal? (radiation-case-grid case) 'grid-placeholder))

(test-case "visualization handles forward update and window lifecycle actions"
  (define updated #f)
  (define visible? #t)
  (define handle
    (make-visualization-handle
     (lambda (data) (set! updated data))
     (lambda () (set! visible? #t))
     (lambda () (set! visible? #f))
     (lambda () visible?)))
  (check-true (visualization-handle? handle))
  (visualization-update! handle 'replacement)
  (check-eq? updated 'replacement)
  (check-true (visualization-open? handle))
  (visualization-close! handle)
  (check-false (visualization-open? handle))
  (visualization-show! handle)
  (check-true (visualization-open? handle)))

(test-case "data cursor selects the nearest finite harvested sample"
  (define first-series
    (cursor-series "A"
                   (list (vector 100 2)
                         (vector 101 +nan.0)
                         (vector 102 4))
                   "steelblue"))
  (define second-series
    (cursor-series "B"
                   (list (vector 100 8) (vector 102 10))
                   "firebrick"))
  (define selection
    (nearest-cursor-sample
     (list first-series second-series)
     101.8 4.1 values))
  (check-eq? (cursor-selection-series selection) first-series)
  (check-equal? (cursor-selection-point selection) (vector 102 4)))

(test-case "headless plot legends preserve external panel presentation"
  (define item (plot-legend-item "S21 (output <- input)"
                                 "firebrick" 'short-dash 'line))
  (check-equal? (plot-legend-item-label item) "S21 (output <- input)")
  (check-equal? (plot-legend-item-color item) "firebrick")
  (check-eq? (plot-legend-item-style item) 'short-dash)
  (check-eq? (plot-legend-item-kind item) 'line))

(test-case "NEC2C report parser preserves multiple feeds and polarization"
  (define report (parse-nec2c-output parser-fixture))
  (check-equal? (length (parsed-nec2c-report-feeds report)) 2)
  (check-= (magnitude
            (- (parsed-nec2c-feed-voltage
                (second (parsed-nec2c-report-feeds report)))
               0+1i))
           0 1e-12)
  (check-= (magnitude
            (- (parsed-nec2c-feed-impedance
                (first (parsed-nec2c-report-feeds report)))
               100))
           0 1e-12)
  (check-equal? (length (parsed-nec2c-report-patterns report)) 2)
  (check-eq? (parsed-nec2c-pattern-polarization-sense
              (first (parsed-nec2c-report-patterns report)))
             'left)
  (check-false
   (parsed-nec2c-pattern-total-gain-db
   (second (parsed-nec2c-report-patterns report)))))

(test-case "VSWR plots auto-scale unless an explicit ceiling is requested"
  (define (frequency-sample frequency vswr)
    (define feedpoint
      (nec2c-feedpoint-sample
       "feed-1" frequency 1 1 1 1 50 1/50 1/2))
    (nec2c-sweep-frequency
     frequency
     (list (nec2c-sweep-sample feedpoint 0 +inf.0 vswr))))
  (define sweep
    (nec2c-sweep-result
     #f 50
     (list (frequency-sample 1 2)
           (frequency-sample 2 20)
           (frequency-sample 3 +inf.0))))
  (define auto-line (first (vswr-sweep-renderers sweep)))
  (define capped-line
    (first (vswr-sweep-renderers sweep #:max-vswr 10)))
  (check-equal?
   (ivl-max (vector-ref (plot-element-bounds-rect auto-line) 1))
   20)
  (check-equal?
   (ivl-max (vector-ref (plot-element-bounds-rect capped-line) 1))
   10))

(test-case "return-loss plots dip downward and ignore an exact-match infinity"
  (define (frequency-sample frequency return-loss)
    (define feedpoint
      (nec2c-feedpoint-sample
       "feed-1" frequency 1 1 1 1 50 1/50 1/2))
    (nec2c-sweep-frequency
     frequency
     (list (nec2c-sweep-sample feedpoint 0 return-loss 1))))
  (define sweep
    (nec2c-sweep-result
     #f 50
     (list (frequency-sample 1 3)
           (frequency-sample 2 20)
           (frequency-sample 3 +inf.0))))
  (define auto-line (first (return-loss-sweep-renderers sweep)))
  (define capped-line
    (first
     (return-loss-sweep-renderers sweep #:floor-db -12)))
  (check-equal?
   (ivl-min (vector-ref (plot-element-bounds-rect auto-line) 1))
   -20)
  (check-equal?
   (ivl-min (vector-ref (plot-element-bounds-rect capped-line) 1))
   -12))

(test-case "Smith chart renders dense light and dark normalized grids"
  (define (smith-frequency frequency impedance)
    (define gamma (/ (- impedance 50) (+ impedance 50)))
    (define magnitude* (magnitude gamma))
    (define return-loss
      (if (zero? magnitude*) +inf.0 (* -20 (/ (log magnitude*) (log 10)))))
    (define vswr
      (if (= magnitude* 1) +inf.0 (/ (+ 1 magnitude*) (- 1 magnitude*))))
    (define feedpoint
      (nec2c-feedpoint-sample
       "feed-1" frequency 1 1 1 1 impedance (/ impedance) 1/2))
    (nec2c-sweep-frequency
     frequency
     (list (nec2c-sweep-sample feedpoint gamma return-loss vswr))))
  (define sweep
    (nec2c-sweep-result
     #f 50
     (list (smith-frequency 100 25-10i)
           (smith-frequency 101 50+0i)
           (smith-frequency 102 100+25i))))
  (define light-renderers
    (smith-chart-renderers sweep #:markers? #t #:theme 'light))
  (define dark-renderers
    (smith-chart-renderers sweep #:markers? #f #:theme 'dark))
  (check-true (> (length light-renderers) 40))
  (check-true (> (length light-renderers) (length dark-renderers)))
  (define preview
    (plot-bitmap light-renderers
                 #:x-min -1.08 #:x-max 1.08
                 #:y-min -1.08 #:y-max 1.08
                 #:aspect-ratio 1
                 #:width 400 #:height 400))
  (check-equal? (send preview get-width) 400)
  (check-equal? (send preview get-height) 400)
  (check-exn #rx"light.*dark"
             (lambda () (smith-chart-renderers sweep #:theme 'sepia)))
  (check-exn #rx"boolean"
             (lambda () (smith-chart-renderers sweep #:markers? 'yes))))

(define integration-executable
  (or (getenv "NEC2C")
      (find-executable-path "nec2c")))

(when integration-executable
  (test-case "NEC2C round trip supports named quadrature feeds and data renderers"
    (reset-model!)
    (model title "Crossed dipoles"
           frequency 299.792458
           impedance 50
           max-length 0.024)
    (wire-on)
    (spread forward 0.5 feed (center "X" 1 0))
    (spread left 0.5 feed (center "Y" 1 90))
    (nec2c-executable integration-executable)

    (define impedance (nec2c-measure-impedance))
    (check-equal? (map nec2c-feedpoint-sample-feed-name
                       (nec2c-impedance-result-samples impedance))
                  '("X" "Y"))
    (check-= (imag-part
              (nec2c-feedpoint-sample-voltage
               (second (nec2c-impedance-result-samples impedance))))
             1.0 1e-6)

    (define sweep (nec2c-vswr-sweep 295 305 #:steps 3))
    (check-equal? (length (nec2c-sweep-result-frequencies sweep)) 3)
    (check-true
     (andmap (lambda (frequency)
               (= (length (nec2c-sweep-frequency-feed-samples frequency)) 2))
             (nec2c-sweep-result-frequencies sweep)))
    (check-equal? (nec2c-sweep-result-reference-impedance sweep) 50)
    (check-not-false (pair? (vswr-sweep-renderers sweep)))
    (check-not-false (pair? (return-loss-sweep-renderers sweep)))
    (check-not-false (pair? (impedance-sweep-renderers sweep)))
    (check-not-false (pair? (smith-chart-renderers sweep)))

    (define azimuth (nec2c-azimuth-pattern #:step 30))
    (check-equal? (length (nec2c-pattern-samples azimuth)) 13)
    (check-not-false (pair? (radiation-cut-renderers azimuth)))

    (define elevation (nec2c-elevation-pattern #:step 30))
    (check-equal? (length (nec2c-pattern-samples elevation)) 13)
    (check-not-false (pair? (radiation-cut-renderers elevation)))

    (define grid
      (nec2c-radiation-grid #:theta-step 90 #:phi-step 90))
    (check-equal? (length (nec2c-pattern-grid-samples grid)) 12)
    (define zenith
      (for/first ([sample (in-list (nec2c-pattern-grid-samples grid))]
                  #:when (and (= (nec2c-pattern-sample-theta-deg sample) 0)
                              (= (nec2c-pattern-sample-phi-deg sample) 0)))
        sample))
    (check-not-false zenith)
    (check-= (nec2c-pattern-sample-axial-ratio zenith) 1.0 1e-4)
    (check-not-false
     (memq (nec2c-pattern-sample-polarization-sense zenith) '(left right)))
    (check-not-false (pair? (radiation-grid-renderers grid)))
    (check-not-false
     (plot3d-bitmap (radiation-grid-renderers grid)
                    #:width 160 #:height 120))))

(when integration-executable
  (test-case "NEC2C analysis decorates but does not modify an explicit export"
    (reset-model!)
    (model frequency 299.792458 max-length 0.024)
    (wire-on)
    (spread forward 0.5 feed center)
    (nec2c-executable integration-executable)
    (define directory
      (make-temporary-file "antenna-turtle-explicit-nec~a" 'directory
                           (current-directory)))
    (define base-path (build-path directory "dipole.nec"))
    (export-nec2c base-path)
    (define original (file->bytes base-path))
    (define result (nec2c-measure-impedance #:keep-artifacts? #t))
    (define artifacts
      (nec2c-run-info-artifacts (nec2c-impedance-result-run result)))
    (check-equal? (simple-form-path (nec2c-artifacts-model-path artifacts))
                  (simple-form-path base-path))
    (check-true (file-exists? (nec2c-artifacts-input-path artifacts)))
    (check-equal? (file->bytes base-path) original)
    (delete-directory/files
     (path-only (nec2c-artifacts-input-path artifacts)))
    (delete-directory/files directory)))

(when integration-executable
  (test-case "NEC2C grounded analysis uses the upper hemisphere"
    (reset-model!)
    (model title "Elevated dipole over perfect ground"
           frequency 299.792458
           ground perfect
           height 1/4
           max-length 0.024)
    (wire-on)
    (spread forward 0.5 feed center)
    (nec2c-executable integration-executable)

    (check-equal?
     (length (nec2c-impedance-result-samples (nec2c-measure-impedance)))
     1)
    (model-ground 'real)
    (check-equal?
     (length (nec2c-impedance-result-samples (nec2c-measure-impedance)))
     1)
    (model-ground 'perfect)
    (define azimuth (nec2c-azimuth-pattern #:step 90))
    (check-equal? (length (nec2c-pattern-samples azimuth)) 5)
    (check-exn #rx"nonnegative elevation"
               (lambda ()
                 (nec2c-azimuth-pattern #:elevation -10 #:step 90)))

    (define elevation (nec2c-elevation-pattern #:step 30))
    (check-equal? (length (nec2c-pattern-samples elevation)) 7)
    (check-equal?
     (map nec2c-pattern-sample-elevation-deg
          (nec2c-pattern-samples elevation))
     '(0.0 30.0 60.0 90.0 60.0 30.0 0.0))
    (check-equal?
     (map nec2c-pattern-sample-azimuth-deg
          (nec2c-pattern-samples elevation))
     '(0.0 0.0 0.0 0.0 180.0 180.0 180.0))
    (check-not-false (pair? (radiation-cut-renderers elevation)))

    (define grid (nec2c-radiation-grid #:theta-step 90 #:phi-step 90))
    (check-equal? (nec2c-pattern-grid-theta-values grid) '(0 90))
    (check-equal? (length (nec2c-pattern-grid-samples grid)) 8)
    (check-not-false
     (plot3d-bitmap (radiation-grid-renderers grid)
                    #:width 160 #:height 120))))
