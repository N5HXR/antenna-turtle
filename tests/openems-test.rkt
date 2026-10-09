#lang racket

(require rackunit
         racket/file
         (prefix-in m: manifold)
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

(test-case "OpenEMS NF2FF postprocessing accepts the command runner result"
  ;; This exercises the subprocess boundary without launching OpenEMS.  It
  ;; guards the four-value run-command protocol used by cancellation support.
  (define directory
    (make-temporary-file "antenna-turtle-openems-nf2ff-run~a" 'directory))
  (define simulation-directory (build-path directory "simulation"))
  (make-directory simulation-directory)
  (define mock-octave (build-path directory "mock-octave"))
  (call-with-output-file mock-octave
    #:exists 'truncate/replace
    (lambda (out)
      (displayln "#!/bin/sh" out)
      (displayln "printf '0,0,1,0,0,0\\n180,0,1,0,0,0\\n' > simulation/nf2ff-900MHz.csv" out)
      (displayln "printf '900000000,2,0.5\\n' > simulation/nf2ff-900MHz-metadata.csv" out)))
  (file-or-directory-permissions mock-octave #o755)
  (define artifacts
    (openems-artifacts
     directory
     (build-path directory "run-openems.m")
     simulation-directory
     (build-path directory "simulation-manifest.rktd")
     #t #t))
  (define manifest
    (hash 'format_version 1
          'status "complete"
          'elapsed_ms 1234
          'exit_code 0
          'sweep (hash 'start_mhz 800 'stop_mhz 1000)
          'model_frequency_mhz 900
          'port (hash 'name "feed" 'impedance_ohms 50)
          'solver (hash 'octave_executable "/missing/saved/octave")
          'solver_to_user_transform
          '((0 0 1 0) (0 1 0 0) (-1 0 0 0))))
  (call-with-output-file (openems-artifacts-manifest-path artifacts)
    #:exists 'truncate/replace
    (lambda (out) (write manifest out) (newline out)))
  (call-with-output-file (build-path simulation-directory "port-results.csv")
    #:exists 'truncate/replace
    (lambda (out) (displayln "900000000,0,0,50,0,-inf.0" out)))
  (define run
    (openems-run-info mock-octave 0 0 "" "" artifacts manifest))
  (define result
    (openems-sweep-result
     run "feed" 50
     (list (openems-port-sample 900 0 50 -inf.0))))
  (dynamic-wind
    void
    (lambda ()
      (define grid
        (openems-radiation-grid result
                                #:frequency 900
                                #:theta-step 180
                                #:phi-step 360
                                #:octave mock-octave))
      (check-equal? (length (nec2c-pattern-grid-samples grid)) 2)
      (check-= (nec2c-pattern-sample-total-gain-db
                (first (nec2c-pattern-grid-samples grid)))
               (* 10 (/ (log 2) (log 10)))
               1e-10)
      (define loaded (openems-load-artifacts directory))
      (check-equal? (length (openems-sweep-result-samples loaded)) 1)
      ;; A matching saved NF2FF grid is reused without resolving or launching
      ;; the deliberately nonexistent saved Octave executable.
      (define loaded-grid
        (openems-radiation-grid loaded
                                #:frequency 900
                                #:theta-step 180
                                #:phi-step 360))
      (check-equal? (length (nec2c-pattern-grid-samples loaded-grid)) 2)
      (openems-close! loaded)
      (check-true (directory-exists? directory)))
    (lambda () (openems-close! artifacts))))

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

(test-case "OpenEMS prepares dielectric bodies and transformed conducting sheets"
  (reset-model!)
  (model frequency 915)
  (define substrate-material
    (dielectric #:name 'substrate #:relative-permittivity 4.4))
  (define copper
    (conducting-sheet-material #:name 'copper
                               #:conductivity 5.8e7
                               #:thickness 35e-6))
  (define substrate (m:cube 0.1 0.1 0.002))
  (body substrate geometry substrate material substrate-material priority 10)
  (turn left 30)
  (sheet ground
    points '((0 0) (0.1 0) (0.1 0.1) (0 0.1))
    material copper
    priority 20)
  (turn right 30)
  (move up 0.001)
  (port up gap 0.002 width 0.001 depth 0.001)
  (define mock-octave (make-temporary-file "mock-octave~a"))
  (call-with-output-file mock-octave
    #:exists 'truncate/replace
    (lambda (out) (displayln "#!/bin/sh" out) (displayln "exit 0" out)))
  (file-or-directory-permissions mock-octave #o755)
  (define failure
    (with-handlers ([exn:fail:openems? values])
      (openems-sweep 850 950
                     #:octave mock-octave
                     #:progress? #f)
      #f))
  (check-true (exn:fail:openems? failure))
  (define run (exn:fail:openems-run-info failure))
  (define artifacts (openems-run-info-artifacts run))
  (define driver (file->string (openems-artifacts-driver-path artifacts)))
  (check-regexp-match #rx"AddMaterial" driver)
  (check-regexp-match #rx"SetMaterialProperty" driver)
  (check-regexp-match #rx"AddConductingSheet" driver)
  (check-regexp-match #rx"AddPolygon" driver)
  (check-regexp-match #rx"'Matrix'" driver)
  (check-regexp-match #rx"AddLumpedPort\\(CSX, 15, 1," driver)
  (define manifest (openems-run-info-manifest run))
  (check-equal? (length (hash-ref manifest 'geometry)) 2)
  (check-equal? (hash-ref (hash-ref manifest 'port) 'priority) 15)
  (check-equal? (hash-ref (hash-ref manifest 'port) 'priority_source)
                "automatic")
  (define mesh (hash-ref manifest 'mesh))
  (check-= (hash-ref mesh 'maximum_refractive_index)
           (sqrt 4.4) 1e-12)
  (check-equal? (hash-ref mesh 'minimum_dielectric_cells_per_extent) 4)
  ;; The port transform centers the 2 mm substrate on solver Z.  Its two
  ;; interfaces plus three derived interior coordinates make four cells
  ;; through the dielectric without changing global cells-per-wavelength.
  (define substrate-z-lines
    (filter (lambda (value) (<= -0.0010000001 value 0.0010000001))
            (hash-ref mesh 'critical_z)))
  (check-equal? (length substrate-z-lines) 5)
  (for ([actual (in-list substrate-z-lines)]
        [expected (in-list '(-0.001 -0.0005 0 0.0005 0.001))])
    (check-= actual expected 1e-12))
  (openems-close! artifacts)
  (delete-file mock-octave)
  (m:solid-close! substrate)
  (clear-bodies))

(test-case "OpenEMS derives ordinary turtle wires as a gapped capsule body"
  (reset-model!)
  (model frequency 915 impedance 50)
  (with-wire
    (spread up (* 0.47 wavelength) feed center))
  (define mock-octave (make-temporary-file "mock-octave~a"))
  (call-with-output-file mock-octave
    #:exists 'truncate/replace
    (lambda (out) (displayln "#!/bin/sh" out) (displayln "exit 0" out)))
  (file-or-directory-permissions mock-octave #o755)
  (define failure
    (with-handlers ([exn:fail:openems? values])
      (openems-sweep 800 1050
                     #:wire-segments 16
                     #:octave mock-octave
                     #:progress? #f)
      #f))
  (check-true (exn:fail:openems? failure))
  (define run (exn:fail:openems-run-info failure))
  (define artifacts (openems-run-info-artifacts run))
  (define driver (file->string (openems-artifacts-driver-path artifacts)))
  (check-regexp-match #rx"ImportSTL" driver)
  (define manifest (openems-run-info-manifest run))
  (define conversion (hash-ref manifest 'wire_conversion))
  (check-equal? (hash-ref conversion 'representation) "capsule-union")
  (check-equal? (hash-ref conversion 'edge_count) 1)
  (check-equal? (hash-ref conversion 'circular_segments) 16)
  (check-equal? (hash-ref conversion 'feed_edge_id) 1)
  (check-true (positive? (hash-ref conversion 'derived_feed_gap_m)))
  ;; Conversion is a snapshot, not a mutation of the physical scene.
  (check-equal? (model-bodies) '())
  (check-equal? (model-ports) '())
  (openems-close! artifacts)
  (delete-file mock-octave)
  (clear-wires))

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
