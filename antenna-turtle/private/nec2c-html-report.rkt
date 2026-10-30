#lang racket/base

(require json
         racket/file
         racket/format
         racket/list
         racket/math
         racket/path
         racket/promise
         racket/runtime-path
         racket/string
         "core.rkt"
         "export-nec2c.rkt"
         "material.rkt"
         "nec2c-dielectric.rkt"
         "nec2c-result-json.rkt"
         "nec2c.rkt"
         "wire-lumped.rkt"
         "wire-network.rkt")

(provide write-html-report write-nec2c-html-report)

(define-runtime-path viewer-bundle "report-assets/viewer.bundle.js")
(define-runtime-path openems-html-report-path "html-report.rkt")
;; Do not make the optional Manifold-backed surface reporter a compilation
;; dependency of the wire-only report writer.
(define-runtime-path nec2c-surface-module "nec2c-surface.rkt")

(define surface-api
  (delay
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (for/hash ([name
                  (in-list
                   '(model-nec2c-surface-geometry
                     nec2c-surface-geometry-patches
                     nec2c-surface-geometry-attachments
                     nec2c-surface-patch-body-name
                     nec2c-surface-patch-center
                     nec2c-surface-patch-normal
                     nec2c-surface-patch-area
                     nec2c-surface-patch-corners
                     nec2c-surface-attachment-wire-id
                     nec2c-surface-attachment-end
                     nec2c-surface-attachment-displacement
                     nec2c-adjusted-edge-point))])
        (values name (dynamic-require nec2c-surface-module name))))))

(define (surface-call name . arguments)
  (define api (force surface-api))
  (and api (apply (hash-ref api name) arguments)))

(define (write-json-script value destination)
  ;; Stream JSON directly into the HTML file.  Large NEC reports can contain
  ;; both a dense spherical pattern and several field planes; materializing
  ;; that JSON as one string and then copying it through regexp-replace* causes
  ;; extreme GC/memory pressure.  This output port preserves the script-safe
  ;; `<` escape while forwarding every other byte without an intermediate
  ;; aggregate string.
  (define (write-chunk bytes start end _non-block? _breakable?)
    (let loop ([cursor start] [segment-start start])
      (define less-than
        (for/first ([index (in-range cursor end)]
                    #:when (= (bytes-ref bytes index) 60))
          index))
      (cond
        [less-than
         (when (< segment-start less-than)
           (write-bytes bytes destination segment-start less-than))
         (write-bytes #"\\u003c" destination)
         (loop (add1 less-than) (add1 less-than))]
        [else
         (when (< segment-start end)
           (write-bytes bytes destination segment-start end))]))
    (- end start))
  (define escaped
    (make-output-port 'json-script always-evt write-chunk void))
  (write-json value escaped)
  (close-output-port escaped))

(define (finite-real? value)
  (and (real? value)
       (let ([converted (exact->inexact value)])
         (and (not (nan? converted))
              (not (infinite? converted))))))

;; JSON has no representation for IEEE infinities or NaN.  These values can
;; arise legitimately in idealized network results (for example, exact zero
;; reflection or an open circuit), so report them as unavailable rather than
;; allowing the complete portable-report write to fail.
(define (json-real value)
  (if (finite-real? value) (exact->inexact value) 'null))

(define (real-json value)
  (and (finite-real? value) (exact->inexact value)))

(define (complex-report value)
  (hash 'real (json-real (real-part value))
        'imaginary (json-real (imag-part value))
        'magnitude (json-real (magnitude value))
        'phase_degrees
        (if (zero? value)
            0.0
            (json-real (* 180 (/ (angle value) pi))))))

(define (point-report point)
  (list (exact->inexact (point3-x point))
        (exact->inexact (point3-y point))
        (exact->inexact (point3-z point))))

(define (solver-point-report point)
  (list (exact->inexact (point3-x point))
        (exact->inexact (point3-y point))
        (exact->inexact (+ (point3-z point) (model-height)))))

(define (solver-coordinate-list-report coordinates)
  (list (exact->inexact (list-ref coordinates 0))
        (exact->inexact (list-ref coordinates 1))
        (exact->inexact (+ (list-ref coordinates 2) (model-height)))))

(define (feed-report edge)
  (and (wire-edge-feed? edge)
       (hash 'name (format "~a" (wire-edge-feed-name edge))
             'fraction (case (wire-edge-feed-location edge)
                         [(start) 0.0]
                         [(center) 0.5]
                         [else 1.0])
             'amplitude (wire-edge-feed-amplitude edge)
             'phase_degrees (wire-edge-feed-phase edge))))

(define (geometry-report)
  (define surface-candidate
    (surface-call 'model-nec2c-surface-geometry))
  (define surfaces
    (and surface-candidate
         (pair?
          (surface-call
           'nec2c-surface-geometry-patches surface-candidate))
         surface-candidate))
  (define (edge-point edge end)
    (if surfaces
        (surface-call 'nec2c-adjusted-edge-point surfaces edge end)
        (vertex-point
         ((if (eq? end 'start) wire-edge-start wire-edge-end) edge))))
  (define loads (resolve-wire-loads 'write-nec2c-html-report))
  (define endpoint-overrides (wire-load-endpoint-overrides loads))
  (define port-by-edge
    (for/hash ([port (in-list (model-wire-ports))])
      (values (wire-port-declaration-edge port) port)))
  (define coax-by-edge (make-hasheq))
  (for* ([coax (in-list (model-wire-coaxes))]
         [edge (in-list (wire-coax-declaration-shield-edges coax))])
    (hash-set! coax-by-edge edge coax))
  (define (resolved-edge-point edge end)
    (define ends (hash-ref endpoint-overrides edge #f))
    (if (and ends (hash-has-key? ends end))
        (hash-ref ends end)
        (edge-point edge end)))
  (define (edge-report edge)
    (define port (hash-ref port-by-edge edge #f))
    (define coax (hash-ref coax-by-edge edge #f))
    (hash 'id (wire-edge-id edge)
          'start (solver-point-report (resolved-edge-point edge 'start))
          'end (solver-point-report (resolved-edge-point edge 'end))
          'diameter (json-real (wire-edge-diameter edge))
          'segment_count
          (nec2c-edge-segment-count edge (maximum-segment-length))
          'feed (or (feed-report edge) 'null)
          'role (cond [port "port"] [coax "coax-shield"] [else "wire"])
          'name (cond [port (format "~a" (wire-port-declaration-name port))]
                      [coax (format "~a shield" (wire-coax-declaration-name coax))]
                      [else (format "wire ~a" (wire-edge-id edge))])
          'coax (if coax (format "~a" (wire-coax-declaration-name coax)) 'null)
          'color (if (and coax (wire-coax-declaration-color coax))
                     (format "~a" (wire-coax-declaration-color coax))
                     'null)))
  (define (load-report load)
    (define element (resolved-wire-load-element load))
    (hash
     'name (format "~a" (wire-lumped-element-name element))
     'tag (resolved-wire-load-tag load)
     'start (solver-point-report (resolved-wire-load-negative-point load))
     'end (solver-point-report (resolved-wire-load-positive-point load))
     'center (solver-point-report (wire-lumped-element-center element))
     'diameter (json-real (resolved-wire-load-diameter load))
     'topology (format "~a" (wire-lumped-element-topology element))
     'resistance_ohms (json-real (or (wire-lumped-element-resistance element) 0))
     'inductance_h (json-real (or (wire-lumped-element-inductance element) 0))
     'capacitance_f (json-real (or (wire-lumped-element-capacitance element) 0))
     'negative_wire_id (wire-edge-id (resolved-wire-load-negative-edge load))
     'positive_wire_id (wire-edge-id (resolved-wire-load-positive-edge load))))
  (hash
   'grounded (model-grounded?)
   'wires
   (append
    (map edge-report (model-edges))
    (for/list ([load (in-list loads)])
      (define report (load-report load))
      (hash 'id (resolved-wire-load-tag load)
            'start (hash-ref report 'start)
            'end (hash-ref report 'end)
            'diameter (hash-ref report 'diameter)
            'segment_count 1
            'feed 'null
            'role "lumped-load"
            'name (hash-ref report 'name)
            'coax 'null
            'color "dark orange")))
   'ports
   (for/list ([port (in-list (model-wire-ports))])
     (hash 'name (format "~a" (wire-port-declaration-name port))
           'wire_id (wire-edge-id (wire-port-declaration-edge port))
           'negative (solver-point-report (wire-port-negative-point port))
           'positive (solver-point-report (wire-port-positive-point port))
           'generated (wire-port-declaration-generated? port)))
   'transmission_lines
   (for/list ([line (in-list (model-wire-transmission-lines))])
     (hash
      'name (format "~a" (wire-transmission-line-name line))
      'input_port
      (format "~a" (wire-port-declaration-name
                     (wire-transmission-line-input-port line)))
      'output_port
      (format "~a" (wire-port-declaration-name
                     (wire-transmission-line-output-port line)))
      'impedance_ohms (json-real (wire-transmission-line-impedance line))
      'physical_length_m (json-real (wire-transmission-line-physical-length line))
      'velocity_factor (json-real (wire-transmission-line-velocity-factor line))
      'electrical_length_m
      (json-real (/ (wire-transmission-line-physical-length line)
                    (wire-transmission-line-velocity-factor line)))))
   'coaxes
   (for/list ([coax (in-list (model-wire-coaxes))])
     (hash
      'name (format "~a" (wire-coax-declaration-name coax))
      'shield_wire_ids
      (map wire-edge-id (wire-coax-declaration-shield-edges coax))
      'input_port
      (format "~a" (wire-port-declaration-name
                     (wire-coax-declaration-input-port coax)))
      'output_port
      (format "~a" (wire-port-declaration-name
                     (wire-coax-declaration-output-port coax)))
      'diameter (json-real (wire-coax-declaration-diameter coax))
      'color (if (wire-coax-declaration-color coax)
                 (format "~a" (wire-coax-declaration-color coax))
                 'null)))
   'lumped_loads (map load-report loads)
   'surface_patches
   (if surfaces
       (for/list ([patch
                   (in-list
                    (surface-call 'nec2c-surface-geometry-patches surfaces))])
         (hash
          'body (format "~a" (surface-call 'nec2c-surface-patch-body-name patch))
          'center
          (solver-point-report
           (surface-call 'nec2c-surface-patch-center patch))
          'normal
          (point-report (surface-call 'nec2c-surface-patch-normal patch))
          'area (exact->inexact (surface-call 'nec2c-surface-patch-area patch))
          'corners
          (for/list ([corner
                      (in-list
                       (surface-call 'nec2c-surface-patch-corners patch))])
            (solver-point-report corner))))
       '())
   'surface_attachments
   (if surfaces
       (for/list ([attachment
                   (in-list
                    (surface-call
                     'nec2c-surface-geometry-attachments surfaces))])
         (hash
          'wire_id (surface-call 'nec2c-surface-attachment-wire-id attachment)
          'end (format "~a" (surface-call 'nec2c-surface-attachment-end attachment))
          'displacement
          (exact->inexact
           (surface-call 'nec2c-surface-attachment-displacement attachment))))
       '())
   'dielectric_volumes
   (for/list ([volume (in-list (model-cuboids))]
              #:when (eq? (em-material-kind (model-cuboid-material volume))
                          'dielectric))
     (define-values (minimum maximum) (model-cuboid-bounds volume))
     (define material (model-cuboid-material volume))
     (hash
      'name (format "~a" (model-cuboid-name volume))
      'minimum (solver-coordinate-list-report minimum)
      'maximum (solver-coordinate-list-report maximum)
      'material
      (hash 'name (format "~a" (em-material-name material))
            'relative_permittivity
            (exact->inexact (em-material-relative-permittivity material))
            'conductivity_s_per_m
            (exact->inexact (em-material-electric-conductivity material)))))))

(define (feedpoint-sample-report frequency sample reflection return-loss vswr)
  (define feedpoint
    (cond
      [(nec2c-sweep-sample? sample) (nec2c-sweep-sample-feedpoint sample)]
      [(nec2c-gain-sweep-sample? sample) (nec2c-gain-sweep-sample-feedpoint sample)]))
  (hash 'port (format "~a" (nec2c-feedpoint-sample-feed-name feedpoint))
        'frequency_mhz (json-real frequency)
        's11_db (json-real (- return-loss))
        'reflection_coefficient (complex-report reflection)
        'impedance_ohms
        (complex-report (nec2c-feedpoint-sample-impedance feedpoint))))

(define (sweep-measurements result)
  (define reference (nec2c-sweep-result-reference-impedance result))
  (define samples
    (for*/list ([frequency (in-list (nec2c-sweep-result-frequencies result))]
                [sample (in-list (nec2c-sweep-frequency-feed-samples frequency))])
      (feedpoint-sample-report
       (nec2c-sweep-frequency-frequency-mhz frequency)
       sample
       (nec2c-sweep-sample-reflection-coefficient sample)
       (nec2c-sweep-sample-return-loss-db sample)
       (nec2c-sweep-sample-vswr sample))))
  (define names (remove-duplicates (map (lambda (sample) (hash-ref sample 'port)) samples)))
  (hash 'ports (for/list ([name (in-list names)])
                 (hash 'name name 'reference_impedance_ohms reference))
        'port_samples samples
        's_parameters '()))

(define (gain-sweep-measurements result)
  (define reference (nec2c-gain-sweep-result-reference-impedance result))
  (define samples
    (for/list ([sample (in-list (nec2c-gain-sweep-result-samples result))])
      (feedpoint-sample-report
       (nec2c-gain-sweep-sample-frequency-mhz sample)
       sample
       (nec2c-gain-sweep-sample-reflection-coefficient sample)
       (nec2c-gain-sweep-sample-return-loss-db sample)
       (nec2c-gain-sweep-sample-vswr sample))))
  (define names (remove-duplicates (map (lambda (sample) (hash-ref sample 'port)) samples)))
  (hash 'ports (for/list ([name (in-list names)])
                 (hash 'name name 'reference_impedance_ohms reference))
        'port_samples samples
        's_parameters '()))

(define (nearest-pattern result target)
  (define samples (nec2c-gain-sweep-result-samples result))
  (when (null? samples)
    (raise-user-error 'write-nec2c-html-report "the gain sweep is empty"))
  (nec2c-gain-sweep-sample-pattern
   (argmin (lambda (sample)
             (abs (- (nec2c-gain-sweep-sample-frequency-mhz sample) target)))
           samples)))

(define (resolve-pattern result supplied-pattern requested-frequency)
  (cond
    [supplied-pattern
     (unless (nec2c-pattern-grid? supplied-pattern)
       (raise-argument-error
        'write-nec2c-html-report "(or/c #f nec2c-pattern-grid?)" supplied-pattern))
     supplied-pattern]
    [(nec2c-gain-sweep-result? result)
     (nearest-pattern result (or requested-frequency (model-frequency)))]
    [else
     (raise-user-error
      'write-nec2c-html-report
      "a NEC2C VSWR sweep needs #:pattern from nec2c-radiation-grid")]))

(define (pattern-frequency pattern)
  (define samples (nec2c-pattern-grid-samples pattern))
  (and (pair? samples)
       (nec2c-pattern-sample-frequency-mhz (first samples))))

(define (pattern-sample-report sample)
  (hash 'theta_deg (exact->inexact (nec2c-pattern-sample-theta-deg sample))
        'phi_deg (exact->inexact (nec2c-pattern-sample-phi-deg sample))
        'elevation_deg (exact->inexact (nec2c-pattern-sample-elevation-deg sample))
        'azimuth_deg (exact->inexact (nec2c-pattern-sample-azimuth-deg sample))
        'vertical_gain_db (or (real-json (nec2c-pattern-sample-vertical-gain-db sample)) 'null)
        'horizontal_gain_db (or (real-json (nec2c-pattern-sample-horizontal-gain-db sample)) 'null)
        'total_gain_db (or (real-json (nec2c-pattern-sample-total-gain-db sample)) 'null)
        'axial_ratio (or (real-json (nec2c-pattern-sample-axial-ratio sample)) 'null)
        'tilt_degrees (or (real-json (nec2c-pattern-sample-tilt-deg sample)) 'null)
        'e_theta (complex-report (nec2c-pattern-sample-e-theta sample))
        'e_phi (complex-report (nec2c-pattern-sample-e-phi sample))
        'polarization
        (let ([sense (nec2c-pattern-sample-polarization-sense sample)])
          (if sense (format "~a" sense) 'null))))

(define (pattern-report pattern)
  (hash 'frequency_mhz (exact->inexact (or (pattern-frequency pattern) (model-frequency)))
        'theta_values (map exact->inexact (nec2c-pattern-grid-theta-values pattern))
        'phi_values (map exact->inexact (nec2c-pattern-grid-phi-values pattern))
        'samples (map pattern-sample-report (nec2c-pattern-grid-samples pattern))))

(define (optional-real value)
  (json-real value))

(define (diagnostics-report diagnostics)
  (if (not diagnostics)
      'null
      (hash
       'frequency_mhz (exact->inexact (nec2c-diagnostics-frequency-mhz diagnostics))
       'segment_samples
       (for/list ([sample (in-list (nec2c-diagnostics-segments diagnostics))])
         (hash 'wire_id (nec2c-segment-sample-wire-id sample)
               'segment (nec2c-segment-sample-segment sample)
               'current (complex-report (nec2c-segment-sample-current sample))
               'charge_density
               (let ([charge (nec2c-segment-sample-charge-density sample)])
                 (if charge (complex-report charge) 'null))))
       'surface_current_samples
       (for/list ([sample
                   (in-list (nec2c-diagnostics-surface-currents diagnostics))])
         (hash 'patch (nec2c-surface-current-sample-patch sample)
               'center (point-report
                        (nec2c-surface-current-sample-center sample))
               'current_density
               (for/list ([component
                           (in-list
                            (nec2c-surface-current-sample-current-density sample))])
                 (complex-report component))))
       'volume_current_samples
       (for/list ([sample
                   (in-list (nec2c-diagnostics-volume-currents diagnostics))])
         (hash
          'cell_id (nec2c-volume-current-sample-cell-id sample)
          'box_id (nec2c-volume-current-sample-box-id sample)
          'region_id (nec2c-volume-current-sample-region-id sample)
          'material_id (nec2c-volume-current-sample-material-id sample)
          'center (point-report (nec2c-volume-current-sample-center sample))
          'size (point-report (nec2c-volume-current-sample-size sample))
          'current_density
          (for/list ([component
                      (in-list
                       (nec2c-volume-current-sample-current-density sample))])
            (complex-report component))))
       'power_budget
       (let ([budget (nec2c-diagnostics-power-budget diagnostics)])
         (if (not budget)
             'null
             (hash
              'input_power_w (optional-real (nec2c-power-budget-input-power budget))
              'radiated_power_w (optional-real (nec2c-power-budget-radiated-power budget))
              'structure_loss_w (optional-real (nec2c-power-budget-structure-loss budget))
              'network_loss_w (optional-real (nec2c-power-budget-network-loss budget))
              'efficiency_percent
              (optional-real (nec2c-power-budget-efficiency-percent budget))))))))

(define (compact-complex-vector-report vector)
  (if vector
      (append-map
       (lambda (value)
         (list (exact->inexact (real-part value))
               (exact->inexact (imag-part value))))
       vector)
      'null))

(define (near-field-report result)
  (if (not result)
      '()
      (for/list ([section (in-list (nec2c-near-field-result-sections result))]
                 [index (in-naturals 1)])
        (hash
         'id index
         'plane (format "~a" (nec2c-near-field-section-plane section))
         'normal_axis (format "~a" (nec2c-near-field-section-normal-axis section))
         'position (exact->inexact (nec2c-near-field-section-position section))
         'u_axis (format "~a" (nec2c-near-field-section-u-axis section))
         'v_axis (format "~a" (nec2c-near-field-section-v-axis section))
         'u_values (map exact->inexact (nec2c-near-field-section-u-values section))
         'v_values (map exact->inexact (nec2c-near-field-section-v-values section))
         'fields (map symbol->string (nec2c-near-field-section-fields section))
         'samples
         (for/list ([sample (in-list (nec2c-near-field-section-samples section))])
           (hash 'electric (compact-complex-vector-report
                            (nec2c-near-field-sample-electric sample))
                 'magnetic (compact-complex-vector-report
                            (nec2c-near-field-sample-magnetic sample))))))))

(define (same-frequency? left right)
  (<= (abs (- left right))
      (* 1e-9 (max 1.0 (abs left) (abs right)))))

(define report-css #<<CSS
:root{color-scheme:dark;font-family:"DejaVu Sans Mono",ui-monospace,monospace;background:#030611;color:#d8fbff}*{box-sizing:border-box}body{margin:0;overflow:hidden;background:radial-gradient(circle at 65% 30%,#151037,#030611 55%)}header{position:fixed;z-index:3;left:18px;top:14px;text-shadow:0 0 12px #31efff;max-width:60vw}h1{margin:0;color:#7df9ff;font-size:20px;letter-spacing:.08em;text-transform:uppercase}#subtitle{margin-top:5px;color:#ff4bd8;font-size:12px}.panel{position:fixed;z-index:4;background:#07101ddd;border:1px solid #31efff88;box-shadow:0 0 22px #00d9ff2f,inset 0 0 18px #002a4133;padding:12px}#metadata-panel{right:18px;top:78px;width:310px;max-height:42vh;overflow:auto}#metadata{white-space:pre-wrap;font-size:10px;color:#93b8c7;margin:0}label{font-size:11px;color:#89eeff}select,button,input{accent-color:#ff3bd4;background:#061322;color:#dff;border:1px solid #29e9ff;padding:5px}button{font-weight:bold;min-width:72px;box-shadow:0 0 10px #ff2fd655}.row{display:flex;align-items:center;gap:9px;margin-top:9px}.row input[type=range]{flex:1}#viewport{width:100vw;height:100vh;display:block}.scanlines{pointer-events:none;position:fixed;z-index:2;inset:0;background:repeating-linear-gradient(0deg,#0000 0,#0000 3px,#4ef1ff09 4px);mix-blend-mode:screen}@media(max-width:800px){#metadata-panel{display:none}header{max-width:45vw}}
CSS
  )

(define (result-run result)
  (cond
    [(nec2c-sweep-result? result) (nec2c-sweep-result-run result)]
    [(nec2c-gain-sweep-result? result) (nec2c-gain-sweep-result-run result)]))

(define (machine-provenance run selected-frequency)
  (define result (nec2c-run-info-machine-result run))
  (if (not result)
      'null
      (let* ([producer (nec2c-machine-result-producer result)]
             [jobs (nec2c-machine-result-jobs result)]
             [executions
              (append*
               (for/list ([job (in-list jobs)])
                 (nec2c-result-job-executions job)))]
             [selected
              (for/first ([execution (in-list executions)]
                          #:when (and
                                  (equal? (nec2c-result-execution-status execution) "ok")
                                  (same-frequency?
                                   selected-frequency
                                   (nec2c-result-execution-frequency-mhz execution))
                                  (pair? (nec2c-result-execution-far-fields execution))))
                execution)])
        (hash
         'schema_version 1
         'completion_status (nec2c-machine-result-completion-status result)
         'producer
         (hash 'program (nec2c-result-producer-program producer)
               'program_version (nec2c-result-producer-program-version producer)
               'dielectric_feature_revision
               (nec2c-result-producer-dielectric-feature-revision producer))
         'diagnostics
         (map nec2c-result-diagnostic-raw
              (nec2c-machine-result-diagnostics result))
         'jobs
         (for/list ([job (in-list jobs)])
           (hash 'job_index (nec2c-result-job-job-index job)
                 'dielectric (nec2c-result-job-dielectric job)
                 'mesh_states (nec2c-result-job-mesh-states job)
                 'ground_states (nec2c-result-job-ground-states job)
                 'omitted_requests (nec2c-result-job-omitted-requests job)))
         'selected_execution
         (if selected
             (hash
              'execution_index (nec2c-result-execution-execution-index selected)
              'frequency_mhz (nec2c-result-execution-frequency-mhz selected)
              'mesh_state_id (nec2c-result-execution-mesh-state-id selected)
              'ground_state_id (nec2c-result-execution-ground-state-id selected)
              'excitation (nec2c-result-execution-excitation selected)
              'trigger (nec2c-result-execution-trigger selected)
              'solver (nec2c-result-execution-solver selected)
              'power (nec2c-result-execution-power selected))
             'null)))))

(define (write-nec2c-html-report result destination
                                  #:pattern [supplied-pattern #f]
                                  #:frequency [requested-frequency #f]
                                  #:near-fields [requested-near-fields 'default]
                                  #:title [title #f])
  (unless (or (nec2c-sweep-result? result) (nec2c-gain-sweep-result? result))
    (raise-argument-error
     'write-nec2c-html-report
     "(or/c nec2c-sweep-result? nec2c-gain-sweep-result?)" result))
  (unless (path-string? destination)
    (raise-argument-error 'write-nec2c-html-report "path-string?" destination))
  (unless (or (not requested-frequency) (real? requested-frequency))
    (raise-argument-error 'write-nec2c-html-report "(or/c #f real?)" requested-frequency))
  (define pattern (resolve-pattern result supplied-pattern requested-frequency))
  (define run (result-run result))
  (define selected-frequency (pattern-frequency pattern))
  (define near-fields
    (cond
      [(not requested-near-fields) #f]
      [(nec2c-near-field-result? requested-near-fields)
       (unless (same-frequency?
                selected-frequency
                (nec2c-near-field-result-frequency-mhz requested-near-fields))
         (raise-arguments-error
          'write-nec2c-html-report
          "the supplied near fields do not match the report frequency"
          "report frequency (MHz)" selected-frequency
          "near-field frequency (MHz)"
          (nec2c-near-field-result-frequency-mhz requested-near-fields)))
       requested-near-fields]
      [(eq? requested-near-fields 'default)
       (nec2c-near-field-planes #:frequency selected-frequency)]
      [(and (list? requested-near-fields)
            (pair? requested-near-fields)
            (andmap near-field-section? requested-near-fields))
       (nec2c-near-field-planes
        #:frequency selected-frequency #:planes requested-near-fields)]
      [else
       (raise-argument-error
        'write-nec2c-html-report
        "(or/c #f 'default nec2c-near-field-result? (non-empty-listof near-field-section?))"
        requested-near-fields)]))
  (define measurements
    (if (nec2c-sweep-result? result)
        (sweep-measurements result)
        (gain-sweep-measurements result)))
  ;; Ordinary report workflows get diagnostics from the single-frequency
  ;; radiation-grid run. A gain sweep deliberately suppresses the otherwise
  ;; enormous per-frequency current tables, so recover one selected-frequency
  ;; diagnostic snapshot when that is the report's pattern source.
  (define diagnostics
    (or (and near-fields (nec2c-near-field-result-diagnostics near-fields))
        (nec2c-pattern-grid-diagnostics pattern)
        (and (nec2c-gain-sweep-result? result)
             (nec2c-segment-diagnostics selected-frequency))))
  (define report-data
    (hash
     'schema "antenna-turtle-report/nec2c-m1"
     'metadata
     (hash 'title (or title (model-title))
           'subtitle
           (format "NEC2C · ~a MHz radiation and network analysis · portable report"
                   (~r selected-frequency #:precision '(= 4)))
           'model_frequency_mhz (exact->inexact (model-frequency))
           'pattern_frequency_mhz (exact->inexact selected-frequency)
           'grounded (model-grounded?)
           'reference_impedance_ohms
           (if (nec2c-sweep-result? result)
               (nec2c-sweep-result-reference-impedance result)
               (nec2c-gain-sweep-result-reference-impedance result))
           'solver
           (hash 'executable (format "~a" (nec2c-run-info-executable run))
                 'version (format "~a" (nec2c-run-info-version run))
                 'elapsed_ms (nec2c-run-info-elapsed-ms run)
                 'exit_code (nec2c-run-info-exit-code run))
           'machine_provenance (machine-provenance run selected-frequency)
           'measurements measurements)
     'geometry (geometry-report)
     'pattern (pattern-report pattern)
     'diagnostics (diagnostics-report diagnostics)
     'near_fields (near-field-report near-fields)))
  (define complete (simplify-path (path->complete-path destination)))
  (make-parent-directory* complete)
  (call-with-output-file complete
    #:exists 'truncate/replace
    (lambda (out)
      (display "<!doctype html><html><head><meta charset=\"utf-8\">" out)
      (display "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" out)
      (display "<title>Antenna Turtle NEC2C report</title><style>" out)
      (display report-css out)
      (display "</style></head><body><header><h1 id=\"title\"></h1><div id=\"subtitle\"></div></header>" out)
      (display "<canvas id=\"viewport\"></canvas><div class=\"scanlines\"></div>" out)
      (display "<details class=\"panel\" id=\"metadata-panel\"><summary>SIMULATION METADATA</summary><pre id=\"metadata\"></pre></details>" out)
      (display "<script type=\"application/json\" id=\"antenna-turtle-report-data\">" out)
      (write-json-script report-data out)
      (display "</script><script>" out)
      (display (file->string viewer-bundle) out)
      (display "</script></body></html>" out)))
  complete)

;; Keep the common report entry point available in wire-only installations.
;; Loading the OpenEMS writer would otherwise pull in Manifold at module load
;; time, so resolve it only when the result is not a native NEC2C result.
(define (write-html-report result destination
                           #:pattern [pattern #f]
                           #:frequency [frequency #f]
                           #:near-fields [near-fields 'default]
                           #:title [title #f])
  (cond
    [(or (nec2c-sweep-result? result) (nec2c-gain-sweep-result? result))
     (write-nec2c-html-report
      result destination
      #:pattern pattern #:frequency frequency #:near-fields near-fields #:title title)]
    [else
     (when pattern
       (raise-arguments-error
        'write-html-report
        "#:pattern is supported only for NEC2C reports"
        "result" result
        "pattern" pattern))
     (when frequency
       (raise-arguments-error
        'write-html-report
        "#:frequency is supported only for NEC2C reports"
        "result" result
        "frequency" frequency))
     (unless (eq? near-fields 'default)
       (raise-arguments-error
        'write-html-report
        "#:near-fields is supported only for NEC2C reports"
        "result" result
        "near fields" near-fields))
     (define writer
       (with-handlers
           ([exn:fail?
             (lambda (failure)
               (raise-user-error
                'write-html-report
                (string-append
                 "OpenEMS HTML report support is unavailable; install "
                 "Manifold and recompile Antenna Turtle\n  reason: "
                 (exn-message failure))))])
         (dynamic-require openems-html-report-path
                          'write-openems-html-report)))
     (writer result destination #:title title)]))
