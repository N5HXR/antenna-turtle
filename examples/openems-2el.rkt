#lang antenna-turtle

(require (prefix-in m: manifold))

(model title "OpenEMS proof-of-concept dipole"
       frequency 915
       impedance 50
       wire-diameter (* 4 millimeters))

(define gap (max (/ wavelength 200) (/ (current-wire-diameter) 2)))
(define radius (/ wavelength 200))
(define total-length (* 0.47 wavelength))
(define arm-length (/ (- total-length gap) 2))

(define (cylinder-at-z start height radius)
  (define primitive (m:cylinder height radius #:segments 48))
  (define placed (m:translate primitive `(0 0 ,start)))
  (m:solid-close! primitive)
  placed)

(define lower-arm
  (cylinder-at-z (- (+ (/ gap 2) arm-length)) arm-length radius))
(define upper-arm
  (cylinder-at-z (/ gap 2) arm-length radius))
(define reflector
  (m:cylinder (* 2.1 arm-length) radius #:segments 48 #:center? #t))
;  (cylinder-at-z (half gap) (* 2.1 arm-length) radius))

(with-scale 0.88
  (body lower material pec geometry lower-arm priority 20)
  (body upper material pec geometry upper-arm priority 20)

  ;; The turtle is at the feed center. Local +Z is already the desired voltage
  ;; direction, so the backend's automatic solver transform is the identity.
  (port up name "feed" impedance 50 gap gap width gap depth gap)

  (move left quarter-wave)
  (body ref material pec geometry reflector priority 20))

;; Scene registration owns transformed copies.
(m:solid-close! lower-arm)
(m:solid-close! upper-arm)
(m:solid-close! reflector)

(show-solid-model) ; inspect bodies and port before committing to a long run

(define result
  (openems-sweep 800 1050
                 #:steps 101
                 #:keep-artifacts? #t
                 #:end-criteria 1e-4))

(define best
  (argmin (lambda (sample)
            (magnitude (openems-port-sample-reflection-coefficient sample)))
          (openems-sweep-result-samples result)))

(printf "OpenEMS best sampled match: ~a MHz, S11 ~a dB, Z ~a ohms\n"
        (openems-port-sample-frequency-mhz best)
        (openems-port-sample-s11-db best)
        (openems-port-sample-impedance best))
(printf "Artifacts retained in ~a\n"
        (openems-artifacts-directory
         (openems-run-info-artifacts (openems-sweep-result-run result))))

;; The same result can be viewed without converting it by hand:
(show-return-loss-sweep result)
(show-impedance-sweep result)
(show-smith-chart result)

(define pattern
  (openems-radiation-grid result))
  ;; #:frequency 'best-match
  ;; #:frequency 915
  ;; #:theta-step 2
  ;; #:phi-step 2

(show-radiation-pattern-opengl pattern #:palette 'inferno)
