#lang antenna-turtle

;; One ordinary Antenna Turtle wire model drives both solvers. NEC2C consumes
;; the centerlines directly; OpenEMS temporarily turns them into a union of
;; physical Manifold capsules and cuts the marked feed gap from that union.
(model title "Three-element wire Yagi — NEC2C and OpenEMS"
       frequency 915
       impedance 50
       max-length (/ wavelength 40)
       wire-diameter (* 3 millimeter))

(define element-layout
  (list (list 'reflector  0                     (* 0.52 wavelength))
        (list 'driven    (* 0.20 wavelength)   (* 0.48 wavelength))
        (list 'director  (* 0.35 wavelength)   (* 0.45 wavelength))))

(define (build-element role boom-position length)
  (from-here
    (move forward boom-position)
    (with-wire
      (if (eq? role 'driven)
          (spread left length feed center)
          (spread left length)))))

(loop for (role boom-position length) in element-layout
      do (build-element role boom-position length))

(module+ main
  ;; Both viewers describe the same source program. The solid view shows the
  ;; capsule radiators and the physical gap derived for OpenEMS.
  (show-model)
  (show-solid-model #:wire-segments 24)

  (define nec-pattern
    (nec2c-radiation-grid #:theta-step 3 #:phi-step 3))

  (define em-result
    (openems-sweep 800 1050
                   #:steps 101
                   #:wire-segments 24
                   #:keep-artifacts? #t))
  (define em-pattern
    (openems-radiation-grid em-result #:theta-step 3 #:phi-step 3))

  ;; Identical pictures are not expected: one solver sees mathematical wire
  ;; centerlines and the other sees finite capsule solids on a Yee grid. The
  ;; synchronized comparison is useful for spotting gross integration errors
  ;; and understanding the numerical differences.
  (show-radiation-comparison
   (list (radiation-case "NEC2C" nec-pattern)
         (radiation-case "OpenEMS" em-pattern))
   #:aspect-ratio 16/9
   #:palette 'inferno)

  (show-return-loss-sweep em-result)
  (show-smith-chart em-result)

  (printf "OpenEMS artifacts retained in ~a\n"
          (openems-artifacts-directory
           (openems-run-info-artifacts
            (openems-sweep-result-run em-result)))))
