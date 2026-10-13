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

(test-case "OpenEMS parses and plots a complete two-port S matrix"
  (define path (make-temporary-file "antenna-turtle-openems-sparams~a.csv"))
  (dynamic-wind
    (lambda ()
      (call-with-output-file path
        #:exists 'truncate/replace
        (lambda (out)
          (displayln "900000000,1,1,0.1,0,-20" out)
          (displayln "900000000,2,1,0.8,-0.1,-1.8708664336" out)
          (displayln "900000000,1,2,0.79,-0.09,-2.006" out)
          (displayln "900000000,2,2,0.12,0.01,-18.387" out))))
    (lambda ()
      (define samples
        (parse-openems-s-parameter-results path '(input output)))
      (check-equal? (length samples) 4)
      (check-equal? (openems-s-parameter-sample-output-port (second samples))
                    'output)
      (check-equal? (openems-s-parameter-sample-input-port (second samples))
                    'input)
      (define run (openems-run-info #f 0 0 "" "" #f (hash)))
      (define result
        (openems-multiport-result
         run
         (list (openems-result-port 'input 50)
               (openems-result-port 'output 50))
         samples
         (hash
          'input (list (openems-port-sample 900 0.1 61.111  -20))
          'output (list (openems-port-sample 900 0.12+0.01i 63.5 -18.387)))))
      (check-equal? (length (s-parameter-magnitude-renderers result)) 4)
      (check-equal? (length (s-parameter-phase-renderers result)) 4)
      (check-equal?
       (length (network-sweep-samples (openems-sweep->network-sweep result)))
       2)
      (define mixed-reference-result
        (struct-copy openems-multiport-result result
          [ports (list (openems-result-port 'input 50)
                       (openems-result-port 'output 75))]))
      (check-exn #rx"require every port to use the same reference impedance"
                 (lambda ()
                   (openems-sweep->network-sweep mixed-reference-result))))
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
  (call-with-output-file (build-path simulation-directory "port-power.csv")
    #:exists 'truncate/replace
    (lambda (out) (displayln "900000000,1,1,1,0.1,0.9" out)))
  (call-with-output-file (build-path simulation-directory "dielectric-power.csv")
    #:exists 'truncate/replace
    (lambda (out) (displayln "900000000,1,0.1" out)))
  (call-with-output-file (build-path simulation-directory "lumped-power.csv")
    #:exists 'truncate/replace
    (lambda (out) (displayln "900000000,1,1,0.05" out)))
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
      (define budget
        (power-budget result
                      #:frequency 900
                      #:theta-step 180
                      #:phi-step 360
                      #:octave mock-octave))
      (check-= (openems-power-budget-incident-power-w budget) 1 1e-12)
      (check-= (openems-power-budget-radiated-power-w budget) 0.5 1e-12)
      (check-= (openems-power-budget-dielectric-power-w budget) 0.1 1e-12)
      (check-= (openems-power-budget-lumped-power-w budget) 0.05 1e-12)
      (check-=
       (openems-power-budget-conductor-and-unaccounted-power-w budget)
       0.25 1e-12)
      (check-regexp-match #rx"Conductors / numerical remainder"
                          (format-power-budget budget))
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
               (openems-sweep 800 1000 #:minimum-dielectric-cells 0)))
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
    (dielectric #:name 'substrate #:relative-permittivity 4.4
                #:loss-tangent 0.02 #:loss-frequency 'model))
  (define copper
    (conducting-sheet-material #:name 'copper
                               #:conductivity 5.8e7
                               #:thickness 35e-6))
  (define substrate (m:cube 0.1 0.1 0.002))
  (body name substrate geometry substrate material substrate-material priority 10)
  (turn left 30)
  (sheet name ground
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
                     #:minimum-dielectric-cells 8
                     #:progress? #f)
      #f))
  (check-true (exn:fail:openems? failure))
  (define run (exn:fail:openems-run-info failure))
  (define artifacts (openems-run-info-artifacts run))
  (define driver (file->string (openems-artifacts-driver-path artifacts)))
  (check-regexp-match #rx"AddMaterial" driver)
  (check-regexp-match #rx"SetMaterialProperty" driver)
  (check-regexp-match #rx"'Density', 1" driver)
  (check-regexp-match #rx"'Kappa', 0\\.00[1-9]" driver)
  (check-regexp-match #rx"AddDump\\(CSX, 'dielectric_loss'.*'DumpType', 29"
                      driver)
  (check-regexp-match #rx"CalcSAR" driver)
  (check-regexp-match #rx"port-power[.]csv" driver)
  (check-regexp-match #rx"AddConductingSheet" driver)
  (check-regexp-match #rx"AddPolygon" driver)
  (check-regexp-match #rx"'Matrix'" driver)
  (check-regexp-match #rx"AddLumpedPort\\(CSX, 15, 1," driver)
  (define manifest (openems-run-info-manifest run))
  (check-equal? (length (hash-ref manifest 'geometry)) 2)
  (define dielectric-manifest
    (hash-ref (first (hash-ref manifest 'geometry)) 'material))
  (check-equal? (hash-ref dielectric-manifest 'loss_tangent) 0.02)
  (check-equal? (hash-ref dielectric-manifest 'loss_reference_frequency_mhz) 915)
  (check-true
   (> (hash-ref dielectric-manifest 'electric_conductivity_s_per_m) 0))
  (check-= (hash-ref dielectric-manifest 'electric_conductivity_s_per_m)
           (* 2 pi 915e6 8.8541878128e-12 4.4 0.02)
           1e-14)
  (check-= (hash-ref dielectric-manifest
                     'effective_loss_tangent_at_sweep_start)
           (* 0.02 (/ 915 850))
           1e-12)
  (check-= (hash-ref dielectric-manifest
                     'effective_loss_tangent_at_sweep_stop)
           (* 0.02 (/ 915 950))
           1e-12)
  (check-equal? (hash-ref (hash-ref manifest 'port) 'priority) 15)
  (check-equal? (hash-ref (hash-ref manifest 'port) 'priority_source)
                "automatic")
  (define mesh (hash-ref manifest 'mesh))
  (check-= (hash-ref mesh 'maximum_refractive_index)
           (sqrt 4.4) 1e-12)
  (check-equal? (hash-ref mesh 'minimum_dielectric_cells_per_extent) 8)
  ;; The port transform centers the 2 mm substrate on solver Z. Its two
  ;; interfaces plus seven derived interior coordinates make eight cells
  ;; through the dielectric without changing global cells-per-wavelength.
  (define substrate-z-lines
    (filter (lambda (value) (<= -0.0010000001 value 0.0010000001))
            (hash-ref mesh 'critical_z)))
  (check-equal? (length substrate-z-lines) 9)
  (for ([actual (in-list substrate-z-lines)]
        [expected (in-list '(-0.001 -0.00075 -0.0005 -0.00025 0
                            0.00025 0.0005 0.00075 0.001))])
    (check-= actual expected 1e-12))
  (openems-close! artifacts)
  (delete-file mock-octave)
  (m:solid-close! substrate)
  (clear-bodies))

(test-case "OpenEMS exports rectilinear conductor bodies as aligned boundary sheets"
  (reset-model!)
  (model frequency 435)
  (define block (m:cube 0.04 0.03 0.01 #:center? #t))
  (body name shield geometry block material aluminum
        metal-thickness 0.001 precedence 20 coordinates world)
  (port up name feed gap 0.002 width 0.002 depth 0.002)
  (define mock-octave (make-temporary-file "mock-octave~a"))
  (call-with-output-file mock-octave
    #:exists 'truncate/replace
    (lambda (out) (displayln "#!/bin/sh" out) (displayln "exit 0" out)))
  (file-or-directory-permissions mock-octave #o755)
  (define failure
    (with-handlers ([exn:fail:openems? values])
      (openems-sweep 400 470 #:octave mock-octave #:progress? #f)
      #f))
  (check-true (exn:fail:openems? failure))
  (define artifacts
    (openems-run-info-artifacts (exn:fail:openems-run-info failure)))
  (define driver (file->string (openems-artifacts-driver-path artifacts)))
  (check-regexp-match #rx"AddConductingSheet\\(CSX, 'body_1', 35000000" driver)
  (check-equal? (length (regexp-match* #rx"body_1_facet_[0-9]+ =" driver)) 12)
  (check-false (regexp-match? #rx"ImportSTL\\(CSX, 'body_1'" driver))
  (define body-description
    (first (hash-ref (openems-run-info-manifest
                      (exn:fail:openems-run-info failure))
                     'geometry)))
  (check-equal? (hash-ref body-description 'representation)
                "rectilinear-conducting-boundary")
  (check-equal? (hash-ref body-description 'surface_facet_count) 12)
  (check-equal? (hash-ref body-description 'metal_thickness_m) 0.001)
  (check-true (< (hash-ref body-description 'effective_metal_thickness_m)
                 0.001))
  (openems-close! artifacts)
  (delete-file mock-octave)
  (m:solid-close! block)
  (clear-bodies))

(test-case "OpenEMS rejects oblique finite-conductivity body facets"
  (reset-model!)
  (model frequency 435)
  (define block (m:cube 0.04 0.03 0.01 #:center? #t))
  (define mock-octave (make-temporary-file "mock-octave~a"))
  (call-with-output-file mock-octave
    #:exists 'truncate/replace
    (lambda (out) (displayln "#!/bin/sh" out) (displayln "exit 0" out)))
  (file-or-directory-permissions mock-octave #o755)
  ;; Rotate the geometry itself to produce a genuinely oblique boundary.
  (define rotated (m:rotate block 0 0 30))
  (body name shield geometry rotated material steel
        metal-thickness 0.001 precedence 20 coordinates world)
  (port up name feed gap 0.002 width 0.002 depth 0.002)
  (check-exn
   #rx"boundary facet to align with the Yee grid"
   (lambda ()
     (openems-sweep 400 470 #:octave mock-octave #:progress? #f)))
  (delete-file mock-octave)
  (m:solid-close! rotated)
  (m:solid-close! block)
  (clear-bodies))

(test-case "OpenEMS exports an axis-aligned lumped RLC element"
  (reset-model!)
  (model frequency 435 impedance 50)
  ;; Two conductor sheets meet the component's opposite Z terminal faces.
  (sheet name lower
    points '((-0.01 -0.01) (0.01 -0.01) (0.01 0.01) (-0.01 0.01))
    material pec priority 20)
  (move up 0.002)
  (sheet name upper
    points '((-0.01 -0.01) (0.01 -0.01) (0.01 0.01) (-0.01 0.01))
    material pec priority 20)
  (move down 0.001)
  (lumped-element up
    name matching-part
    resistance (* 2 ohms)
    inductance (* 4.7 nanohenries)
    capacitance (* 8.2 picofarads)
    topology series
    caps #f
    gap 0.002
    size '(0.001 0.001))
  (port up name feed gap 0.002 size '(0.0005 0.0005) priority 15)
  (define mock-octave (make-temporary-file "mock-octave~a"))
  (call-with-output-file mock-octave
    #:exists 'truncate/replace
    (lambda (out) (displayln "#!/bin/sh" out) (displayln "exit 0" out)))
  (file-or-directory-permissions mock-octave #o755)
  (define failure
    (with-handlers ([exn:fail:openems? values])
      (openems-sweep 400 470 #:octave mock-octave #:progress? #f)
      #f))
  (check-true (exn:fail:openems? failure))
  (define run (exn:fail:openems-run-info failure))
  (define driver
    (file->string
     (openems-artifacts-driver-path (openems-run-info-artifacts run))))
  (check-regexp-match #rx"AddLumpedElement" driver)
  (check-regexp-match #rx"'Caps', 0" driver)
  (check-regexp-match #rx"'R', 2" driver)
  (check-regexp-match #rx"'L', 0[.]0000000047" driver)
  (check-regexp-match #rx"'C', 0[.]0000000000082" driver)
  (check-regexp-match #rx"'LEtype', 1" driver)
  (check-regexp-match #rx"AddBox" driver)
  (check-regexp-match #rx"AddProbe\\(CSX, 'lumped_ut1'" driver)
  (check-regexp-match #rx"AddProbe\\(CSX, 'lumped_it1'" driver)
  (check-regexp-match #rx"lumped-power[.]csv" driver)
  (define manifest (openems-run-info-manifest run))
  (check-equal? (length (hash-ref manifest 'lumped_elements)) 1)
  (check-equal? (hash-ref (first (hash-ref manifest 'lumped_elements))
                          'topology)
                "series")
  (define element-manifest (first (hash-ref manifest 'lumped_elements)))
  (check-false (hash-ref element-manifest 'caps))
  (define mesh (hash-ref manifest 'mesh))
  (for ([boundary (in-list (append (hash-ref element-manifest 'minimum_m)
                                   (hash-ref element-manifest 'maximum_m)))]
        [axis (in-list '(x y z x y z))])
    (check-not-false
     (member boundary (hash-ref mesh (string->symbol (format "critical_~a" axis))))))
  (openems-close! (openems-run-info-artifacts run))
  (delete-file mock-octave)
  (clear-bodies))

(test-case "OpenEMS accepts a lumped element flush with conductor sheets"
  (reset-model!)
  (model frequency 435 impedance 50)
  (with-scale millimeters
    (move up 1.6)
    (sheet name left-terminal
      points '((-10 -5) (-0.5 -5) (-0.5 5) (-10 5))
      material pec priority 20)
    (sheet name right-terminal
      points '((0.5 -5) (10 -5) (10 5) (0.5 5))
      material pec priority 20)
    ;; The one-millimeter-high component has its bottom face exactly on the
    ;; z=1.6 mm sheets. Inexact scaling must not require artificial overlap.
    (move up 0.5)
    (lumped-element forward
      name flush-capacitor
      capacitance (* 2.2 picofarads)
      gap 1
      size '(3 1))
    (port up name feed gap 1 size '(1 1) priority 15))
  (define mock-octave (make-temporary-file "mock-octave~a"))
  (call-with-output-file mock-octave
    #:exists 'truncate/replace
    (lambda (out) (displayln "#!/bin/sh" out) (displayln "exit 0" out)))
  (file-or-directory-permissions mock-octave #o755)
  (define failure
    (with-handlers ([exn:fail:openems? values])
      (openems-sweep 350 520 #:octave mock-octave #:progress? #f)
      #f))
  (check-true (exn:fail:openems? failure))
  (openems-close!
   (openems-run-info-artifacts (exn:fail:openems-run-info failure)))
  (delete-file mock-octave)
  (clear-bodies))

(test-case "OpenEMS multiport export preserves coordinates and excites each port"
  (reset-model!)
  (model frequency 915 impedance 50)
  (define block (m:cube 0.1 0.02 0.002 #:center? #t))
  (body name substrate geometry block
        material (dielectric #:relative-permittivity 2.2)
        priority 10)
  (port up name 'input gap 0.002 width 0.002 depth 0.002 priority 15)
  (move forward 0.04)
  (port up name 'output gap 0.002 width 0.002 depth 0.002 priority 15)
  (define mock-octave (make-temporary-file "mock-octave~a"))
  (call-with-output-file mock-octave
    #:exists 'truncate/replace
    (lambda (out)
      (displayln "#!/bin/sh" out)
      (displayln "mkdir -p simulation/excitation-1 simulation/excitation-2" out)
      (displayln "printf '900000000,0.1,0,55,0,-20\\n' > simulation/excitation-1/port-results.csv" out)
      (displayln "printf '900000000,0.2,0,60,0,-13.9794\\n' > simulation/excitation-2/port-results.csv" out)
      (displayln "printf '900000000,1,1,0.1,0,-20\\n900000000,2,1,0.8,0,-1.9382\\n900000000,1,2,0.79,0,-2.0475\\n900000000,2,2,0.2,0,-13.9794\\n' > simulation/s-parameters.csv" out)
      (displayln "printf '0,0,1,0,0,0\\n180,0,1,0,0,0\\n' > simulation/excitation-2/nf2ff-output_915_0MHz.csv" out)
      (displayln "printf '915000000,2,0.5\\n' > simulation/excitation-2/nf2ff-output_915_0MHz-metadata.csv" out)))
  (file-or-directory-permissions mock-octave #o755)
  (define result
    (openems-sweep 850 950 #:octave mock-octave #:progress? #f))
  (check-true (openems-multiport-result? result))
  (check-equal? (length (openems-multiport-result-s-parameters result)) 4)
  (define run (openems-multiport-result-run result))
  (define manifest (openems-run-info-manifest run))
  (check-equal? (hash-ref manifest 'port_count) 2)
  (check-equal? (hash-ref manifest 'user_to_solver_transform)
                '((1.0 0.0 0.0 0.0)
                  (0.0 1.0 0.0 0.0)
                  (0.0 0.0 1.0 0.0)))
  (define driver
    (file->string
     (openems-artifacts-driver-path (openems-run-info-artifacts run))))
  (check-equal? (length (regexp-match* #rx"RunOpenEMS" driver)) 2)
  (check-regexp-match #rx"excitation 1 of 2" driver)
  (check-regexp-match #rx"excitation 2 of 2" driver)
  (check-regexp-match #rx"port[{]1[}].*true" driver)
  (check-regexp-match #rx"port[{]2[}].*true" driver)
  (check-regexp-match #rx"simulation/s-parameters.csv" driver)
  (define output-pattern
    (openems-radiation-grid result
                            #:excitation 'output
                            #:theta-step 180
                            #:phi-step 360))
  (check-equal? (length (nec2c-pattern-grid-samples output-pattern)) 2)
  (define loaded
    (openems-load-artifacts
     (openems-artifacts-directory (openems-run-info-artifacts run))))
  (check-true (openems-multiport-result? loaded))
  (check-equal? (length (openems-multiport-result-s-parameters loaded)) 4)
  (openems-close! loaded)
  (openems-close! result)
  (delete-file mock-octave)
  (m:solid-close! block)
  (clear-bodies))

(test-case "OpenEMS applies 1/3--2/3 refinement to selected metal sheet edges"
  (reset-model!)
  (model frequency 915 impedance 50)
  (define substrate-material
    (dielectric #:name 'substrate #:relative-permittivity 4.4))
  (define substrate (m:cube 0.1 0.1 0.002 #:center? #t))
  (body name substrate geometry substrate material substrate-material priority 10)
  (from-here
    (move down 0.001)
    (sheet name ground
      points '((-0.05 -0.05) (0.05 -0.05) (0.05 0.05) (-0.05 0.05))
      material pec priority 20 mesh-edges exact))
  (from-here
    (move up 0.001)
    (sheet name patch
      points '((-0.02 -0.015) (0.02 -0.015) (0.02 0.015) (-0.02 0.015))
      material pec priority 20 mesh-edges metal))
  (port up name 'feed gap 0.002 width 0.002 depth 0.002)
  (define mock-octave (make-temporary-file "mock-octave~a"))
  (call-with-output-file mock-octave
    #:exists 'truncate/replace
    (lambda (out) (displayln "#!/bin/sh" out) (displayln "exit 0" out)))
  (file-or-directory-permissions mock-octave #o755)
  (define failure
    (with-handlers ([exn:fail:openems? values])
      (openems-sweep 850 950 #:octave mock-octave #:progress? #f)
      #f))
  (check-true (exn:fail:openems? failure))
  (define run (exn:fail:openems-run-info failure))
  (define manifest (openems-run-info-manifest run))
  (define mesh (hash-ref manifest 'mesh))
  (define resolution (hash-ref mesh 'metal_edge_resolution_m))
  (define x-lines (hash-ref mesh 'critical_x))
  (define y-lines (hash-ref mesh 'critical_y))
  (define (contains-near? values wanted)
    (for/or ([value (in-list values)]) (< (abs (- value wanted)) 1e-10)))
  ;; Exact patch edges are replaced by the official pair: R/3 inward and
  ;; 2R/3 outward. Ground and dielectric boundaries remain exact.
  (for ([edge (in-list '(-0.02 0.02))])
    (check-false (contains-near? x-lines edge)))
  (for ([wanted (in-list
                 (list (- -0.02 (* 2/3 resolution))
                       (+ -0.02 (/ resolution 3))
                       (- 0.02 (/ resolution 3))
                       (+ 0.02 (* 2/3 resolution))))])
    (check-true (contains-near? x-lines wanted)))
  (for ([edge (in-list '(-0.015 0.015))])
    (check-false (contains-near? y-lines edge)))
  (for ([wanted (in-list
                 (list (- -0.015 (* 2/3 resolution))
                       (+ -0.015 (/ resolution 3))
                       (- 0.015 (/ resolution 3))
                       (+ 0.015 (* 2/3 resolution))))])
    (check-true (contains-near? y-lines wanted)))
  (for ([boundary (in-list '(-0.05 0.05))])
    (check-true (contains-near? x-lines boundary))
    (check-true (contains-near? y-lines boundary)))
  (define patch-manifest
    (findf (lambda (item) (equal? (hash-ref item 'name) "patch"))
           (hash-ref manifest 'geometry)))
  (check-equal? (hash-ref patch-manifest 'mesh_edges) "metal")
  (openems-close! (openems-run-info-artifacts run))
  (delete-file mock-octave)
  (m:solid-close! substrate)
  (clear-bodies))

(test-case "OpenEMS refines oblique turtle traces by profile width"
  (reset-model!)
  (model frequency 915 impedance 50)
  (with-scale millimeters
    (with-traces 3
      name curved-trace
      (move forward 20)
      (turn left 45)
      (move forward 10))
    (port up name feed gap 1 size '(3 3)))
  (define mock-octave (make-temporary-file "mock-octave~a"))
  (call-with-output-file mock-octave
    #:exists 'truncate/replace
    (lambda (out) (displayln "#!/bin/sh" out) (displayln "exit 0" out)))
  (file-or-directory-permissions mock-octave #o755)
  (define failure
    (with-handlers ([exn:fail:openems? values])
      (openems-sweep 850 950 #:octave mock-octave #:progress? #f)
      #f))
  (check-true (exn:fail:openems? failure))
  (define mesh
    (hash-ref (openems-run-info-manifest
               (exn:fail:openems-run-info failure))
              'mesh))
  (check-equal? (hash-ref mesh 'minimum_trace_cells_across) 3)
  (define x-lines (sort (hash-ref mesh 'critical_x) <))
  (check-true
   (for/or ([left (in-list x-lines)] [right (in-list (rest x-lines))])
     (and (positive? (- right left))
          (<= (- right left) 0.0010000001))))
  (openems-close!
   (openems-run-info-artifacts (exn:fail:openems-run-info failure)))
  (delete-file mock-octave)
  (clear-bodies))

(test-case "matching port faces preserve turtle-trace metal-edge meshing"
  (reset-model!)
  (model frequency 1000 impedance 50)
  (define substrate-material
    (dielectric #:name 'substrate #:relative-permittivity 4.4))
  (with-scale millimeters
    (with-material substrate-material
      (cuboid name board size '(80 50 1.6) anchor bottom))
    (sheet rect name ground size '(80 50)
           material pec mesh-edges metal precedence 20)
    (move back 20 up 0.8)
    (port up name 'input gap 1.6 size '(1.5 1.5))
    (move up 0.8 back 0.75)
    (with-traces 1.5
      name test-trace
      material pec
      precedence 20
      (move forward 40))
    (move back 0.75 down 0.8)
    (port up name 'output gap 1.6 size '(1.5 1.5)))
  (define mock-octave (make-temporary-file "mock-octave~a"))
  (call-with-output-file mock-octave
    #:exists 'truncate/replace
    (lambda (out) (displayln "#!/bin/sh" out) (displayln "exit 0" out)))
  (file-or-directory-permissions mock-octave #o755)
  (define failure
    (with-handlers ([exn:fail:openems? values])
      (openems-sweep 900 1100 #:octave mock-octave #:progress? #f)
      #f))
  (check-true (exn:fail:openems? failure))
  (define manifest
    (openems-run-info-manifest (exn:fail:openems-run-info failure)))
  (define mesh (hash-ref manifest 'mesh))
  (define y-lines (hash-ref mesh 'critical_y))
  (define z-lines (hash-ref mesh 'critical_z))
  (define (contains-near? values wanted)
    (for/or ([value (in-list values)]) (< (abs (- value wanted)) 1e-10)))
  (define trace-width 0.0015)
  (define half-width (/ trace-width 2))
  (define edge-resolution
    (min (hash-ref mesh 'metal_edge_resolution_m)
         (/ trace-width (hash-ref mesh 'minimum_trace_cells_across))))
  ;; The port is exactly as wide as the trace, but its transverse faces must
  ;; not restore exact grid lines on the conductor boundaries.
  (check-false (contains-near? y-lines (- half-width)))
  (check-false (contains-near? y-lines half-width))
  (for ([wanted
         (in-list
          (list (- (- half-width) (* 2/3 edge-resolution))
                (+ (- half-width) (/ edge-resolution 3))
                (- half-width (/ edge-resolution 3))
                (+ half-width (* 2/3 edge-resolution))))])
    (check-true (contains-near? y-lines wanted)))
  ;; The port's two terminal planes remain locked to ground and trace.
  (check-true (contains-near? z-lines 0))
  (check-true (contains-near? z-lines 0.0016))
  (openems-close!
   (openems-run-info-artifacts (exn:fail:openems-run-info failure)))
  (delete-file mock-octave)
  (clear-bodies))

(test-case "OpenEMS rejects a rotated frame in a multiport model"
  (reset-model!)
  (model frequency 915)
  (define block (m:cube 0.1 0.02 0.002 #:center? #t))
  (body name substrate geometry block)
  (port up name 'aligned)
  (turn left 17)
  (port up name 'rotated)
  (define mock-octave (make-temporary-file "mock-octave~a"))
  (call-with-output-file mock-octave
    #:exists 'truncate/replace
    (lambda (out) (displayln "#!/bin/sh" out) (displayln "exit 0" out)))
  (file-or-directory-permissions mock-octave #o755)
  (check-exn #rx"rotated.*global X/Y/Z axes"
             (lambda ()
               (openems-sweep 850 950
                              #:octave mock-octave #:progress? #f)))
  (delete-file mock-octave)
  (m:solid-close! block)
  (clear-bodies))

(test-case "OpenEMS locks user mesh points and planes into critical coordinates"
  (reset-model!)
  (model frequency 915)
  (define block (m:cube 0.1 0.1 0.01 #:center? #t))
  (body name radiator geometry block)
  (port up name 'feed gap 0.002 width 0.002 depth 0.002)
  (move forward 0.012 left 0.013 up 0.014)
  (mesh-point)
  (mesh-plane xy)
  (define mock-octave (make-temporary-file "mock-octave~a"))
  (call-with-output-file mock-octave
    #:exists 'truncate/replace
    (lambda (out) (displayln "#!/bin/sh" out) (displayln "exit 0" out)))
  (file-or-directory-permissions mock-octave #o755)
  (define failure
    (with-handlers ([exn:fail:openems? values])
      (openems-sweep 850 950 #:octave mock-octave #:progress? #f)
      #f))
  (check-true (exn:fail:openems? failure))
  (define run (exn:fail:openems-run-info failure))
  (define manifest (openems-run-info-manifest run))
  (define driver
    (file->string
     (openems-artifacts-driver-path (openems-run-info-artifacts run))))
  (check-regexp-match #rx"required_x = \\[0\\.012" driver)
  (check-regexp-match #rx"did not retain a required x-axis" driver)
  (define constraints (hash-ref manifest 'mesh_constraints))
  (check-equal? (length constraints) 2)
  (check-equal? (hash-ref (first constraints) 'kind) "point")
  (check-equal? (hash-ref (first constraints) 'solver_axes) '(0 1 2))
  (check-equal? (hash-ref (second constraints) 'kind) "plane")
  (check-equal? (hash-ref (second constraints) 'plane) "xy")
  (check-equal? (hash-ref (second constraints) 'solver_axes) '(2))
  (define mesh (hash-ref manifest 'mesh))
  (define (contains-near? values wanted)
    (for/or ([value (in-list values)]) (< (abs (- value wanted)) 1e-10)))
  (check-true (contains-near? (hash-ref mesh 'critical_x) 0.012))
  (check-true (contains-near? (hash-ref mesh 'critical_y) 0.013))
  (check-true (contains-near? (hash-ref mesh 'critical_z) 0.014))
  (openems-close! (openems-run-info-artifacts run))
  (delete-file mock-octave)
  (m:solid-close! block)
  (clear-bodies))

(test-case "OpenEMS coalesces roundoff-equivalent critical mesh coordinates"
  (reset-model!)
  (model frequency 915)
  (define block (m:cube 0.1 0.1 0.01 #:center? #t))
  (body name radiator geometry block)
  (port up name 'feed gap 0.002 width 0.002 depth 0.002)
  ;; The first pair differs only by accumulated floating-point noise.  The
  ;; second pair is one nanometre apart and must remain distinct; this guards
  ;; against accidentally adopting a wavelength-sized merge tolerance.
  (from-here (move forward 0.012) (mesh-plane yz))
  (from-here (move forward (+ 0.012 1e-17)) (mesh-plane yz))
  (from-here (move forward 0.02) (mesh-plane yz))
  (from-here (move forward (+ 0.02 1e-9)) (mesh-plane yz))
  (define mock-octave (make-temporary-file "mock-octave~a"))
  (call-with-output-file mock-octave
    #:exists 'truncate/replace
    (lambda (out) (displayln "#!/bin/sh" out) (displayln "exit 0" out)))
  (file-or-directory-permissions mock-octave #o755)
  (define failure
    (with-handlers ([exn:fail:openems? values])
      (openems-sweep 850 950 #:octave mock-octave #:progress? #f)
      #f))
  (check-true (exn:fail:openems? failure))
  (define run (exn:fail:openems-run-info failure))
  (define x-lines
    (hash-ref (hash-ref (openems-run-info-manifest run) 'mesh) 'critical_x))
  (define (lines-near wanted radius)
    (filter (lambda (value) (< (abs (- value wanted)) radius)) x-lines))
  (check-equal? (length (lines-near 0.012 1e-12)) 1)
  (check-equal? (length (lines-near 0.02 2e-9)) 2)
  (openems-close! (openems-run-info-artifacts run))
  (delete-file mock-octave)
  (m:solid-close! block)
  (clear-bodies))

(test-case "OpenEMS rejects a mesh plane made oblique by one-port rotation"
  (reset-model!)
  (model frequency 915)
  (define block (m:cube 0.1 0.1 0.01 #:center? #t))
  (body name radiator geometry block)
  (mesh-plane xy)
  (turn down 17)
  (port up name 'feed gap 0.002 width 0.002 depth 0.002)
  (check-exn
   #rx"mesh plane xy.*not aligned with the OpenEMS Yee grid"
   (lambda () (openems-sweep 850 950 #:progress? #f)))
  (m:solid-close! block)
  (clear-bodies))

(test-case "OpenEMS rejects mixed multiport reference impedances"
  (reset-model!)
  (model frequency 915)
  (define block (m:cube 0.1 0.02 0.002 #:center? #t))
  (body name substrate geometry block)
  (port up name 'input impedance 50)
  (move forward 0.04)
  (port up name 'output impedance 75)
  ;; Validation happens before Octave is resolved or artifacts are created.
  (check-exn #rx"requires every port to use the same reference impedance"
             (lambda () (openems-sweep 850 950 #:progress? #f)))
  (m:solid-close! block)
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
