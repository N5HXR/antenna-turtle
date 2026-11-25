#lang racket

(require rackunit
         "../antenna-turtle/main.rkt"
         "../antenna-turtle/private/network.rkt")

(define network
  (network-sweep
   'test #f 50
   (list
    (network-sample 'feed 100 0.1+0.1i 40+10i -16.9897 1.329)
    (network-sample 'feed 200 0.3-0.1i 60-10i -10.0 1.925))))

(test-case "network measurements support exact and rectangular interpolation"
  (check-equal? (impedance-at network 100) 40+10i)
  (check-equal? (impedance-at network 150) 50)
  (check-equal? (admittance-at network 150) 1/50)
  (check-equal? (resistance-at network 150) 50)
  (check-equal? (reactance-at network 150) 0)
  (check-equal? (reflection-at network 150) 0.2+0.0i)
  (check-= (s11-db-at network 150)
           (* 20 (/ (log 0.2) (log 10)))
           1e-10)
  (check-= (return-loss-at network 150)
           (- (* 20 (/ (log 0.2) (log 10))))
           1e-10)
  (check-= (vswr-at network 150) 1.5 1e-12)
  (check-exn #rx"enable interpolation"
             (lambda () (impedance-at network 150 #:interpolate? #f)))
  (check-exn #rx"cannot extrapolate"
             (lambda () (impedance-at network 50))))

(test-case "S11 minimum query returns the deepest sampled null"
  (check-equal? (find-s11-minimum network) '(100 -16.9897)))

(test-case "matching conversions use the model or an explicit system impedance"
  (define impedance 75+0i)
  (define reflection 0.2+0.0i)
  (define return-loss (- (* 20 (/ (log 0.2) (log 10)))))
  (check-= (magnitude
            (- (impedance->reflection-coefficient impedance) reflection))
           0
           1e-12)
  (check-= (impedance->return-loss impedance) return-loss 1e-12)
  (check-= (impedance->vswr impedance) 1.5 1e-12)
  (check-equal? (impedance->reflection-coefficient 100 100) 0)
  (check-equal? (impedance->return-loss 100 100) +inf.0)
  (check-equal? (impedance->vswr 100 100) 1)
  (check-= (reflection-coefficient->return-loss reflection) return-loss 1e-12)
  (check-= (reflection-coefficient->vswr reflection) 1.5 1e-12)
  (check-= (return-loss->vswr return-loss) 1.5 1e-12)
  (check-= (vswr->return-loss 1.5) return-loss 1e-12)
  (check-= (return-loss->vswr +inf.0) 1 0)
  (check-equal? (vswr->return-loss 1) +inf.0)
  (check-exn exn:fail:contract?
             (lambda () (impedance->vswr 50 0)))
  (check-exn exn:fail:contract?
             (lambda () (vswr->return-loss 0.5))))

(test-case "network measurements require a name for ambiguous ports"
  (define two-port
    (struct-copy network-sweep network
      [samples
       (append (network-sweep-samples network)
               (list (network-sample "other" 100 0 75 -inf.0 1)))]))
  (check-exn #rx"multiple ports"
             (lambda () (impedance-at two-port 100)))
  ;; Symbol/string spelling is intentionally interchangeable at the API edge.
  (check-equal? (impedance-at two-port 100 #:port "feed") 40+10i)
  (check-equal? (find-s11-minimum two-port #:port 'other)
                '(100 -inf.0))
  (check-equal? (measurement-ports two-port) '(feed "other")))

(test-case "lossless transmission-line de-embedding recovers antenna impedance"
  (reset-model!)
  (model)
  (wire-port input forward gap 0.01)
  (from-here (move up 1) (wire-port output forward gap 0.01))
  (transmission-line name feedline input input output output
                     impedance 50 physical-length 2.4 velocity-factor 0.66)
  (define frequency 14.1)
  (define load 73+21i)
  (define theta (* 2 pi frequency 1000000 (/ 2.4 (* .66 299792458))))
  (define tangent (tan theta))
  (define input
    (* 50 (/ (+ load (* 0+1i 50 tangent))
             (+ 50 (* 0+1i load tangent)))))
  (define measured
    (network-sweep
     'test #f 50
     (list (network-sample "feedline" frequency 0 input 0 1))))
  (define deembedded (deembed-transmission-line measured 'feedline))
  (check-equal? (measurement-ports deembedded) '("output"))
  (check-= (magnitude (- (impedance-at deembedded frequency) load)) 0 1e-10))

(define (network-with-vswrs pairs)
  (network-sweep
   'test #f 50
   (for/list ([pair (in-list pairs)])
     (define frequency (first pair))
     (define vswr (second pair))
     (define gamma (/ (- vswr 1.0) (+ vswr 1.0)))
     (network-sample 'feed frequency gamma (* 50 vswr)
                     (if (zero? gamma)
                         -inf.0
                         (* 20.0 (/ (log gamma) (log 10.0))))
                     vswr))))

(test-case "multi-match reports thresholds and physically meaningful loss"
  (define result
    (multi-match
     (network-with-vswrs '((3.6 1.0) (7.1 2.0) (14.1 5.0) (28.1 12.0)))
     '(3.6 7.1 14.1 28.1)
     #:interpolate? #f))
  (check-equal? (multi-match-result-good-count result) 2)
  (check-equal? (multi-match-result-usable-count result) 3)
  (check-equal? (multi-match-result-outside-count result) 1)
  (check-equal? (multi-match-result-worst-vswr result) 12.0)
  (check-equal?
   (map multi-match-point-classification (multi-match-result-points result))
   '(good good tunable outside-limit))
  (check-= (multi-match-point-mismatch-loss-db
            (second (multi-match-result-points result)))
           (* -10.0 (/ (log (/ 8.0 9.0)) (log 10.0)))
           1e-12)
  (check-true (<= 0 (multi-match-result-score result) 100)))

(test-case "multi-match ranking protects the worst target band"
  (define broadly-usable
    (multi-match
     (network-with-vswrs '((7.1 2.5) (14.1 3.0) (28.1 4.0)))
     '(7.1 14.1 28.1)))
  (define one-unusable
    (multi-match
     (network-with-vswrs '((7.1 1.1) (14.1 1.2) (28.1 11.0)))
     '(7.1 14.1 28.1)))
  (check-true (multi-match<? broadly-usable one-unusable))
  (check-false (multi-match<? one-unusable broadly-usable)))

(define run (openems-run-info #f 0 0 "" "" #f (hash)))
(define multiport
  (openems-multiport-result
   run
   (list (openems-result-port 'input 50)
         (openems-result-port 'output 50))
   (list
    (openems-s-parameter-sample 100 'input 'input 0.1 -20)
    (openems-s-parameter-sample 200 'input 'input 0.2 -13.9794)
    (openems-s-parameter-sample 100 'output 'input 0.2+0.1i -13.0103)
    (openems-s-parameter-sample 200 'output 'input 0.4-0.1i -7.6955))
   (hash
    'input (list (openems-port-sample 100 0.1 60 -20)
                 (openems-port-sample 200 0.2 70 -13.9794))
    'output (list (openems-port-sample 100 0.1 55 -20)
                  (openems-port-sample 200 0.2 65 -13.9794)))))

(test-case "S-parameter measurements use named source and destination ports"
  (check-equal? (find-s11-minimum multiport #:port 'input)
                '(100 -20))
  (check-= (magnitude
            (- (s-parameter-at multiport 150
                               #:from "input" #:to 'output)
               0.3))
           0
           1e-12)
  (check-= (s-parameter-db-at multiport 150
                              #:from 'input #:to 'output)
           (* 20 (/ (log 0.3) (log 10)))
           1e-10)
  (check-= (s-parameter-phase-at multiport 100
                                 #:from 'input #:to 'output)
           (* (atan 0.1 0.2) (/ 180 pi))
           1e-10)
  (check-equal? (s-parameter-at multiport 100
                                #:from 'input #:to 'input)
                0.1)
  (check-exn #rx"multiple input ports"
             (lambda () (s-parameter-at multiport 100))))

(define (pattern-sample azimuth elevation total-gain
                        [axial-ratio +inf.0] [tilt 0.0] [sense 'linear]
                        [e-theta 1+0i] [e-phi 0+0i])
  (nec2c-pattern-sample
   435 0 azimuth elevation azimuth
   (- total-gain 3) (- total-gain 3) total-gain
   axial-ratio tilt sense e-theta e-phi))

(define grid
  (nec2c-pattern-grid
   #f '(0 90 180) '(0 90 180 270)
   (for*/list ([elevation (in-list '(-90 0 90))]
               [azimuth (in-list '(0 90 180 270))])
     (pattern-sample
      azimuth elevation
      (cond
        [(and (= azimuth 0) (= elevation 0)) 10]
        [(and (= azimuth 180) (= elevation 0)) 0]
        [else -10])))))

(test-case "radiation measurements expose directions, interpolation, and ratios"
  (check-equal? (gain-at grid #:azimuth 0 #:elevation 0) 10)
  ;; Gain interpolation is performed in linear power, not directly in dB.
  (check-= (gain-at grid #:azimuth 45 #:elevation 0)
           (* 10 (/ (log (/ (+ 10.0 0.1) 2.0)) (log 10.0)))
           1e-10)
  (check-exn #rx"enable interpolation"
             (lambda ()
               (gain-at grid #:azimuth 45 #:elevation 0 #:interpolate? #f)))
  (check-equal? (maximum-gain grid) 10)
  (check-equal? (maximum-gain-direction grid) '(0 0))
  (check-= (front-to-back-ratio grid) 10 1e-10)
  (check-= (front-to-side-ratio grid) 20 1e-10)
  (check-true (infinite? (axial-ratio-at grid #:azimuth 90 #:elevation 0)))
  (check-= (polarization-tilt-at grid #:azimuth 90 #:elevation 0) 0.0 1e-12)
  (check-equal? (polarization-sense-at grid #:azimuth 90 #:elevation 0)
                'linear)
  (define-values (e-theta e-phi)
    (e-field-at grid #:azimuth 90 #:elevation 0))
  (check-equal? e-theta 1)
  (check-equal? e-phi 0)
  (check-equal? (pattern-angular-resolution grid) '(90.0 90))
  (check-equal? (measurement-frequencies grid) '(435))
  (check-equal? (measurement-frequency-range grid) '(435 435)))

(test-case "polarization is derived after complex field interpolation"
  (define component (/ 1.0 (sqrt 2.0)))
  (define cut
    (nec2c-pattern
     #f 'azimuth 0
     (list
      (pattern-sample 0 0 0 1 #f 'right
                      component (* 0-1i component))
      (pattern-sample 90 0 0 1 #f 'left
                      component (* 0+1i component)))))
  (check-eq? (polarization-sense-at cut #:azimuth 0 #:elevation 0) 'rhcp)
  (check-eq? (polarization-sense-at cut #:azimuth 90 #:elevation 0) 'lhcp)
  ;; Interpolating the categorical endpoints would be meaningless. Their
  ;; complex midpoint instead has E_phi = 0 and is correctly linear.
  (define midpoint
    (polarization-at cut #:azimuth 45 #:elevation 0))
  (check-eq? (polarization-state-sense midpoint) 'linear)
  (check-true (infinite? (polarization-state-axial-ratio midpoint))))

(test-case "measurement discovery reports frequencies and ports"
  (check-equal? (measurement-frequencies network) '(100 200))
  (check-equal? (measurement-frequency-range network) '(100 200))
  (check-equal? (measurement-frequencies multiport) '(100 200))
  (check-equal? (measurement-ports multiport) '(input output))
  (check-equal?
   (measurement-ports (openems-sweep-result run 'feed 50 '()))
   '(feed)))

(test-case "radiation cuts interpolate along their sampled dimension"
  (define cut
    (nec2c-pattern
     #f 'azimuth 0
     (list (pattern-sample 0 0 10)
           (pattern-sample 90 0 -10)
           (pattern-sample 180 0 0)
           (pattern-sample 270 0 -10))))
  (check-= (gain-at cut #:azimuth 45 #:elevation 0)
           (* 10 (/ (log (/ (+ 10.0 0.1) 2.0)) (log 10.0)))
           1e-10)
  (check-exn #rx"nec2c-pattern-grid"
             (lambda () (front-to-side-ratio cut))))

(test-case "raw NEC impedance results are directly queryable"
  (define result
    (nec2c-impedance-result
     #f
     (list (nec2c-feedpoint-sample
            "feed" 144 1 1 1 0.02 48+2i (/ 48+2i) 0.5))))
  (check-equal? (impedance-at result 144) 48+2i)
  (check-equal? (measurement-ports result) '("feed"))
  (check-equal? (measurement-frequencies result) '(144)))

(define (constant-pattern theta-values gain-db)
  (define phi-values '(0 90 180 270))
  (nec2c-pattern-grid
   #f theta-values phi-values
   (for*/list ([phi (in-list phi-values)]
               [theta (in-list theta-values)])
     (nec2c-pattern-sample
      3.55 theta phi (- 90 theta) phi
      gain-db gain-db gain-db 1 0 'linear 1+0i 0+0i))))

(test-case "absolute power-gain integration produces radiation efficiency"
  (define isotropic (constant-pattern '(0 90 180) 0))
  (check-= (pattern-power-gain-integral isotropic) (* 4 pi) 1e-10)
  (check-= (pattern-air-radiation-efficiency isotropic) 1 1e-10)

  ;; A lossless antenna radiating only into an upper hemisphere has average
  ;; upper-hemisphere power gain 2, or 3.0103 dBi.
  (define lossless-grounded
    (constant-pattern '(0 45 90) (* 10 (/ (log 2) (log 10)))))
  (check-= (pattern-air-radiation-efficiency lossless-grounded) 1 1e-10)

  ;; Unit gain over only the upper hemisphere radiates half of accepted power.
  (define half-efficient (constant-pattern '(0 45 90) 0))
  (check-= (pattern-air-radiation-efficiency half-efficient) 0.5 1e-10))

(define (pattern-with-missing-polar-gain e-theta e-phi)
  (define theta-values '(0 45 90))
  (define phi-values '(0 90 180 270))
  (nec2c-pattern-grid
   #f theta-values phi-values
   (for*/list ([phi (in-list phi-values)]
               [theta (in-list theta-values)])
     (define polar-null? (zero? theta))
     (nec2c-pattern-sample
      3.55 theta phi (- 90 theta) phi
      (and (not polar-null?) 0)
      (and (not polar-null?) 0)
      (and (not polar-null?) 0)
      1 0 'linear
      (if polar-null? e-theta 1+0i)
      (if polar-null? e-phi 0+0i)))))

(test-case "power integration treats an exact field null as zero gain"
  (define polar-null (pattern-with-missing-polar-gain 0+0i 0+0i))
  ;; The 0--45 degree cells average zero at their polar corners and unit gain
  ;; at 45 degrees; the 45--90 degree cells have unit gain throughout.
  (define expected
    (* 2 pi
       (+ (* 0.5 (- 1 (cos (/ pi 4))))
          (cos (/ pi 4)))))
  (check-= (pattern-power-gain-integral polar-null) expected 1e-10)
  ;; Missing gain with a nonzero field is still malformed solver data.
  (check-exn
   #rx"real, non-NaN gain"
   (lambda ()
     (pattern-power-gain-integral
      (pattern-with-missing-polar-gain 1+0i 0+0i)))))

(test-case "NEC power convenience layer includes mismatch and ground residual"
  (define half-efficient (constant-pattern '(0 45 90) 0))
  (define diagnostics
    (nec2c-diagnostics 3.55 '() (nec2c-power-budget 3.55 0.5 0.47 0.01 0.02 94)))
  (set-nec2c-diagnostics-feedpoints!
   diagnostics
   (list (nec2c-feedpoint-sample
          'feed 3.55 1 1 1 0.02 50 (/ 50) 0.5)))
  (set-nec2c-pattern-grid-diagnostics! half-efficient diagnostics)
  (define metrics (analyze-power half-efficient))
  (check-= (radiation-efficiency metrics) 0.5 1e-10)
  (check-= (mismatch-efficiency metrics) 1 1e-10)
  (check-= (realized-efficiency metrics) 0.5 1e-10)
  (check-= (power-metrics-air-radiated-power-w metrics) 0.25 1e-10)
  (check-= (hash-ref (power-loss-breakdown metrics) 'ground-or-unaccounted)
           0.22 1e-10)
  (define report (format-power-report metrics))
  (check-regexp-match #rx"Air radiated" report)
  (check-regexp-match #rx"Radiation efficiency[ ]+50.00%" report)
  (check-regexp-match #rx"Ground / unaccounted loss" report)
  (define out (open-output-string))
  (power-report metrics #:output out)
  (check-equal? (get-output-string out) report))

(test-case "OpenEMS power budgets use the common efficiency interface"
  (define budget
    (openems-power-budget #f 100 'input
                          1.0 0.1 0.9
                          0.0 0.5 0.1 0.05 0.25))
  (check-= (radiation-efficiency budget) (/ 0.5 0.9) 1e-12)
  (check-= (mismatch-efficiency budget) 0.9 1e-12)
  (check-= (realized-efficiency budget) 0.5 1e-12)
  (check-regexp-match #rx"Conductor / unaccounted loss"
                      (format-power-report budget))
  (define directivity-base (constant-pattern '(0 90 180) 0))
  (define directivity-pattern
    (nec2c-pattern-grid
     (hash 'backend 'openems)
     (nec2c-pattern-grid-theta-values directivity-base)
     (nec2c-pattern-grid-phi-values directivity-base)
     (nec2c-pattern-grid-samples directivity-base)))
  (check-exn #rx"directivity, not accepted-power gain"
             (lambda () (radiation-efficiency directivity-pattern))))
