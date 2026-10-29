#lang racket

(require rackunit
         json
         racket/file
         racket/string
         "../antenna-turtle/main.rkt")

(define (bounds->lists volume)
  (call-with-values
   (lambda () (model-cuboid-bounds volume))
   list))

(define foam (dielectric name foam er 3.2 conductivity 0.01))

(test-case "capability schema is strict for consumed fields and forward compatible"
  (define capabilities
    (parse-nec2c-capabilities-jsexpr
     (hasheq
      'program "nec2c-n5hxr"
      'program_version "1.3.1"
      'schema "nec2c-capabilities"
      'schema_version 1
      'features
      (hasheq 'dielectric_feature_revision 1
              'dielectric_resource_versions '(1 2 3)
              'result_json_versions '(1)
              'validate_only #t
              'legacy_result_output #t
              'solvers '("dense" "gmres" "fft")
              'grounds '("free-space" "pec" "sommerfeld-norton")
              'future_feature #t)
      'limits (hasheq 'default_max_cells 1000)
      'future_top_level #t)))
  (check-equal? (nec2c-capability-set-program capabilities) "nec2c-n5hxr")
  (check-true
   (nec2c-capability-supports? capabilities 'dielectric-resource-version 2))
  (check-true (nec2c-capability-supports? capabilities 'solver 'dense))
  (check-false (nec2c-capability-supports? capabilities 'solver 'other))
  (check-exn
   #rx"unknown capability schema version"
   (lambda ()
     (parse-nec2c-capabilities-jsexpr
      (hash-set (nec2c-capability-set-raw capabilities) 'schema_version 2)))))

(define (minimal-result-document)
  (hasheq
   'schema "nec2c-results"
   'schema_version 1
   'producer
   (hasheq 'program "nec2c-n5hxr"
           'program_version "1.3.1"
           'dielectric_feature_revision 1
           'future_producer_field "ignored")
   'input (hasheq 'deck "fixture.nec")
   'jobs
   (list
    (hasheq
     'job_index 0
     'dielectric (hasheq 'resource_version 2)
     'mesh_states '()
     'ground_states '()
     'omitted_requests '()
     'future_job_field 42
     'executions
     (list
      (hasheq
       'execution_index 0
       'status "ok"
       'frequency_mhz 100
       'mesh_state_id 0
       'ground_state_id 0
       'excitation
       (hasheq 'kind "driven-voltage"
               'phasor_convention "exp(+i omega t)")
       'trigger (hasheq 'kind "RP" 'request_index 0 'parameters (hasheq))
       'solver (hasheq 'requested "dense" 'used "dense")
       'material_evaluations '()
       'feeds '()
       'wire_currents '()
       'patch_currents
       (hasheq 'encoding "rows-v1" 'units "A/m"
               'columns '("patch_id" "jx_re")
               'rows '((4 0.25)))
       'volume_currents (json-null)
       'power (hasheq 'basis "driven-accepted-power" 'accepted_w 1.0)
       'far_fields '()
       'near_fields '()))))
   'diagnostics '()
   'completion (hasheq 'status "ok")
   'future_top_level_field "ignored"))

(test-case "result-schema decoder preserves null, raw fields, and rows-v1 mapping"
  (define result (parse-nec2c-result-jsexpr (minimal-result-document)))
  (check-equal? (nec2c-machine-result-completion-status result) "ok")
  (define execution
    (first (nec2c-result-job-executions
            (first (nec2c-machine-result-jobs result)))))
  (check-true
   (nec2c-result-json-null?
    (nec2c-result-execution-volume-currents execution)))
  (define rows (nec2c-result-execution-patch-currents execution))
  (check-equal? (nec2c-result-row-ref rows (first (nec2c-result-rows-rows rows))
                                      "jx_re")
                0.25)
  (check-equal?
   (hash-ref (nec2c-machine-result-raw result) 'future_top_level_field)
   "ignored"))

(test-case "result-schema decoder accepts a failed execution before solver selection"
  (define document (minimal-result-document))
  (define failed-execution
    (hash-set*
     (first (hash-ref (first (hash-ref document 'jobs)) 'executions))
     'status "failed"
     'solver (json-null)))
  (define failed
    (hash-set*
     document
     'jobs
     (list
      (hash-set (first (hash-ref document 'jobs))
                'executions (list failed-execution)))
     'diagnostics
     (list (hasheq 'severity "error"
                   'code "SOLVER_NOT_CONVERGED"
                   'message "iteration limit"
                   'context (hasheq 'job_index 0)))
     'completion (hasheq 'status "solver-error")))
  (define result (parse-nec2c-result-jsexpr failed))
  (check-equal? (nec2c-machine-result-completion-status result) "solver-error")
  (check-true
   (nec2c-result-json-null?
    (nec2c-result-execution-solver
     (first (nec2c-result-job-executions
             (first (nec2c-machine-result-jobs result))))))))

(test-case "result-schema decoder rejects consumed enum and row-contract changes"
  (define unknown-solver
    (hash-set
     (minimal-result-document) 'jobs
     (list
      (hash-update
       (first (hash-ref (minimal-result-document) 'jobs))
       'executions
       (lambda (executions)
         (list
          (hash-update (first executions) 'solver
                       (lambda (solver) (hash-set solver 'used "quantum")))))))))
  (check-exn #rx"unknown value"
             (lambda () (parse-nec2c-result-jsexpr unknown-solver)))
  (define bad-rows
    (hash-set
     (minimal-result-document) 'jobs
     (list
      (hash-update
       (first (hash-ref (minimal-result-document) 'jobs))
       'executions
       (lambda (executions)
         (list
          (hash-update
           (first executions) 'patch_currents
           (lambda (rows) (hash-set rows 'rows '((4)))))))))))
  (check-exn #rx"row width"
             (lambda () (parse-nec2c-result-jsexpr bad-rows))))

(test-case "dielectric materials and volumes do not require a solid body"
  (reset-model!)
  (cuboid
   name nearby-wall
   size '(2 4 6)
   material foam
   anchor center)
  (define volume (first (model-cuboids)))
  (check-equal? (em-material-kind foam) 'dielectric)
  (check-equal? (model-cuboids) (list volume))
  (check-equal? (bounds->lists volume) '((-1 -2 -3) (1 2 3))))

(test-case "volume placement captures turtle translation, scale, and axis permutation"
  (reset-model!)
  (move forward 10)
  (turn left 90)
  (with-scale 2
    (cuboid
     name rotated
     size '(1 2 3)
     material foam
     anchor bottom))
  (define volume (first (model-cuboids)))
  (check-equal? (bounds->lists volume) '((8 -1 0) (12 1 6)))
  ;; The scoped modeling scale is captured by the volume and restored for
  ;; subsequent turtle movement.
  (move forward 1)
  (check-equal? (list (point3-x (current-position))
                      (point3-y (current-position)))
                '(10 1)))

(test-case "oblique cuboids remain valid for solids but are rejected by NEC export"
  (reset-model!)
  (turn left 15)
  (cuboid name oblique size '(1 1 1) material foam)
  (check-exn
   #rx"align with the global X, Y, and Z axes"
   (lambda ()
     (write-nec2c-dielectric-resource (open-output-string)))))

(test-case "reset-model clears dielectric volumes and mesh settings"
  (reset-model!)
  (cuboid name before-reset size '(1 1 1) material foam)
  (nec2c-dielectric-mesh max-kh 0.25 max-cells 50 max-aspect 1)
  (reset-model!)
  (check-equal? (model-cuboids) '())
  (check-equal? (current-nec2c-dielectric-mesh)
                (nec2c-dielectric-mesh-spec 0.5 1000 2.0)))

(test-case "resource-v2 serialization is deterministic and applies model height"
  (reset-model!)
  (model-frequency 100)
  (model-height 0.25)
  (define lossless (dielectric name lossless er 6))
  (cuboid
   name first size '(0.1 0.2 0.3) material lossless anchor bottom)
  (from-here
    (move right 1)
    (cuboid
     name second size '(0.2 0.2 0.2) material foam anchor center))
  (define first-output (open-output-string))
  (write-nec2c-dielectric-resource first-output)
  (define second-output (open-output-string))
  (write-nec2c-dielectric-resource second-output)
  (define text (get-output-string first-output))
  (check-equal? text (get-output-string second-output))
  (check-true (string-prefix? text "NEC2C-DIELECTRIC 2\n"))
  (check-true (string-contains? text "MATERIAL 1 ER 6.000000000000"))
  (check-true
   (string-contains?
    text "MATERIAL 2 ER 3.200000000000 SIGMA 0.010000000000"))
  (check-true
   (string-contains?
    text
    "BOX 1 -0.05 -0.1 0.25 0.05 0.1 0.55"))
  (check-true
   (string-contains?
    text
    "MESH MAX_KH 0.500000000000 MAX_CELLS 1000 MAX_ASPECT 2.000000000000")))

(test-case "dielectric bounds preserve commensurate cell edges"
  (reset-model!)
  (model-frequency 150)
  (define pitch 0.0099930819333)
  (cuboid
   name commensurate
   size (list (* 100 pitch) (* 2 pitch) (* 2 pitch))
   material foam
   anchor center)
  (define output (open-output-string))
  (write-nec2c-dielectric-resource output)
  (define box-line
    (for/first ([line (in-list (string-split (get-output-string output) "\n"))]
                #:when (string-prefix? line "BOX "))
      line))
  (define coordinates
    (map string->number (drop (string-split box-line) 2)))
  (define x-edge (- (list-ref coordinates 3) (list-ref coordinates 0)))
  (define y-edge (- (list-ref coordinates 4) (list-ref coordinates 1)))
  (define z-edge (- (list-ref coordinates 5) (list-ref coordinates 2)))
  (check-= (/ x-edge 100) (/ y-edge 2) 1e-15)
  (check-= (/ x-edge 100) (/ z-edge 2) 1e-15))

(test-case "automatic mesh plans the Yagi wood boom as a safe cubic lattice"
  (reset-model!)
  (define wavelength-150 (frequency->wavelength 150))
  (model frequency 150
         max-length (/ wavelength-150 200)
         wire-diameter (* 6 millimeter))
  (define element-layout
    (list (list 0 (* 0.52 wavelength-150))
          (list (* 1/5 wavelength-150) (* 0.48 wavelength-150))
          (list (* 2/5 wavelength-150) (* 0.45 wavelength-150))))
  (for ([entry (in-list element-layout)])
    (from-here
      (move forward (first entry))
      (with-wire (spread right (second entry)))))
  (define pitch (/ wavelength-150 200))
  (define water-like (dielectric name water-like er 80 loss-tangent 0.01))
  (move forward (* 1/5 wavelength-150) down inch)
  (turn left 90)
  (cuboid name boom
          size (list (/ wavelength-150 2) (* 2 pitch) (* 2 pitch))
          material water-like
          anchor center)
  (nec2c-dielectric-mesh mode auto max-cells 2000)
  (define plan (plan-nec2c-dielectric))
  ;; The coarsest safe solution shortens the metre-long boom by less than the
  ;; allowed lambda/1000 face movement and saves one longitudinal cell.
  (check-equal? (nec2c-dielectric-plan-cell-count plan) 396)
  (check-equal? (fourth (first (nec2c-dielectric-plan-adjusted-boxes plan)))
                '(2 99 2))
  (check-true (<= (nec2c-dielectric-plan-pitch plan)
                  (nec2c-dielectric-plan-minimum-clearance plan)))
  (define output (open-output-string))
  (write-nec2c-dielectric-resource output)
  (define text (get-output-string output))
  (check-true (string-contains? text "# AUTO_MESH"))
  (check-true (string-contains? text "CELLS 396"))
  (check-true (string-contains? text "MAX_ASPECT 1.000000000050")))

(test-case "automatic mesh refuses a snap that cannot clear a conductor"
  (reset-model!)
  (model frequency 300 max-length 0.01 wire-diameter 0.002)
  (with-wire (move forward 0.2))
  (define test-material (dielectric name contact-test er 4))
  (move forward -0.1)
  (cuboid name intersecting size '(0.1 0.1 0.1)
          material test-material anchor center)
  (nec2c-dielectric-mesh mode auto max-cells 10000)
  (check-exn
   #rx"cannot accommodate.*conductor-clearance constraints"
   (lambda () (plan-nec2c-dielectric))))

(test-case "export publishes a relative DF resource and can omit it"
  (reset-model!)
  (model-frequency 100)
  (with-wire (move forward 1 feed start))
  (from-here
    (move right 1)
    (cuboid
     name export-box size '(0.1 0.1 0.1) material foam anchor center))
  (define directory (make-temporary-file "antenna-turtle-dielectric~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (define deck-path (build-path directory "fixture.nec"))
      (define resource-path (build-path directory "fixture.diel"))
      (export-nec2c deck-path)
      (check-true (file-exists? resource-path))
      (define deck (file->string deck-path))
      (check-true (string-contains? deck "GE 0\nDF \"fixture.diel\"\n"))
      (define classic-path (build-path directory "classic.nec"))
      (export-nec2c classic-path #:dielectrics? #f)
      (check-false (string-contains? (file->string classic-path) "DF \""))
      (check-false (file-exists? (build-path directory "classic.diel"))))
    (lambda () (delete-directory/files directory))))

(test-case "dielectric solver controls reject values outside the NEC2C limits"
  (reset-model!)
  (with-wire (move forward 1 feed start))
  (check-exn
   #rx"integer-in 1 10000"
   (lambda ()
     (nec2c-measure-impedance #:solver-iterations 0)))
  (check-exn
   #rx"integer-in 1 10000"
   (lambda ()
     (nec2c-measure-impedance #:solver-iterations 10001)))
  (check-exn
   #rx"positive-real"
   (lambda ()
     (nec2c-measure-impedance #:solver-tolerance 0))))
