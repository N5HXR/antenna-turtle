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
         "nec2c.rkt")

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

(define (real-json value)
  (and (real? value) (exact->inexact value)))

(define (complex-report value)
  (hash 'real (exact->inexact (real-part value))
        'imaginary (exact->inexact (imag-part value))
        'magnitude (exact->inexact (magnitude value))
        'phase_degrees
        (if (zero? value)
            0.0
            (exact->inexact (* 180 (/ (angle value) pi))))))

(define (point-report point)
  (list (exact->inexact (point3-x point))
        (exact->inexact (point3-y point))
        (exact->inexact (point3-z point))))

(define (solver-point-report point)
  (list (exact->inexact (point3-x point))
        (exact->inexact (point3-y point))
        (exact->inexact (+ (point3-z point) (model-height)))))

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
  (hash
   'grounded (model-grounded?)
   'wires
   (for/list ([edge (in-list (model-edges))])
     (hash 'id (wire-edge-id edge)
           'start (solver-point-report (edge-point edge 'start))
           'end (solver-point-report (edge-point edge 'end))
           'diameter (exact->inexact (wire-edge-diameter edge))
           'segment_count
           (edge-segment-count edge (maximum-segment-length))
           'feed (or (feed-report edge) 'null)))
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
       '())))

(define (feedpoint-sample-report frequency sample reflection return-loss vswr)
  (define feedpoint
    (cond
      [(nec2c-sweep-sample? sample) (nec2c-sweep-sample-feedpoint sample)]
      [(nec2c-gain-sweep-sample? sample) (nec2c-gain-sweep-sample-feedpoint sample)]))
  (hash 'port (format "~a" (nec2c-feedpoint-sample-feed-name feedpoint))
        'frequency_mhz (exact->inexact frequency)
        's11_db (- (exact->inexact return-loss))
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
  (if (real? value) (exact->inexact value) 'null))

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
