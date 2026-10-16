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
  (check-equal? (impedance-at network 150 #:interpolate? #t) 50)
  (check-equal? (admittance-at network 150 #:interpolate? #t) 1/50)
  (check-equal? (resistance-at network 150 #:interpolate? #t) 50)
  (check-equal? (reactance-at network 150 #:interpolate? #t) 0)
  (check-equal? (reflection-at network 150 #:interpolate? #t) 0.2+0.0i)
  (check-= (s11-db-at network 150 #:interpolate? #t)
           (* 20 (/ (log 0.2) (log 10)))
           1e-10)
  (check-= (return-loss-at network 150 #:interpolate? #t)
           (- (* 20 (/ (log 0.2) (log 10))))
           1e-10)
  (check-= (vswr-at network 150 #:interpolate? #t) 1.5 1e-12)
  (check-exn #rx"enable interpolation"
             (lambda () (impedance-at network 150)))
  (check-exn #rx"cannot extrapolate"
             (lambda () (impedance-at network 50 #:interpolate? #t))))

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
  (check-equal? (measurement-ports two-port) '(feed "other")))

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
  (check-= (magnitude
            (- (s-parameter-at multiport 150
                               #:from "input" #:to 'output #:interpolate? #t)
               0.3))
           0
           1e-12)
  (check-= (s-parameter-db-at multiport 150
                              #:from 'input #:to 'output #:interpolate? #t)
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
                        [axial-ratio 1.0] [tilt 0.0] [sense 'linear])
  (nec2c-pattern-sample
   435 0 azimuth elevation azimuth
   (- total-gain 3) (- total-gain 3) total-gain
   axial-ratio tilt sense 1+0i 0+1i))

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
  (check-= (gain-at grid #:azimuth 45 #:elevation 0 #:interpolate? #t)
           (* 10 (/ (log (/ (+ 10.0 0.1) 2.0)) (log 10.0)))
           1e-10)
  (check-equal? (maximum-gain grid) 10)
  (check-equal? (maximum-gain-direction grid) '(0 0))
  (check-= (front-to-back-ratio grid) 10 1e-10)
  (check-= (front-to-side-ratio grid) 20 1e-10)
  (check-equal? (axial-ratio-at grid #:azimuth 90 #:elevation 0) 1.0)
  (check-equal? (polarization-tilt-at grid #:azimuth 90 #:elevation 0) 0.0)
  (check-equal? (polarization-sense-at grid #:azimuth 90 #:elevation 0)
                'linear)
  (define-values (e-theta e-phi)
    (e-field-at grid #:azimuth 90 #:elevation 0))
  (check-equal? e-theta 1)
  (check-equal? e-phi 0+1i)
  (check-equal? (pattern-angular-resolution grid) '(90.0 90))
  (check-equal? (measurement-frequencies grid) '(435))
  (check-equal? (measurement-frequency-range grid) '(435 435)))

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
  (check-= (gain-at cut #:azimuth 45 #:elevation 0 #:interpolate? #t)
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
