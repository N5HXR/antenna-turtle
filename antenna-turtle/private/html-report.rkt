#lang racket/base

(require file/gzip
         json
         net/base64
         racket/file
         racket/format
         racket/list
         racket/math
         racket/match
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         "openems.rkt")

(provide write-html-report)

(define-runtime-path viewer-bundle "report-assets/viewer.bundle.js")

(define native-gzip (find-executable-path "gzip"))

(define (result-run result)
  (cond
    [(openems-sweep-result? result) (openems-sweep-result-run result)]
    [(openems-multiport-result? result) (openems-multiport-result-run result)]
    [else
     (raise-argument-error
      'write-html-report
      "(or/c openems-sweep-result? openems-multiport-result?)" result)]))

(define (gzip-bytes/native bytes)
  (and native-gzip
       (with-handlers ([exn:fail? (lambda (_exception) #f)])
         ;; Read stdout while a helper writes stdin so neither pipe can fill
         ;; and block the other.  -n omits host-specific name/time metadata;
         ;; -1 is ample for already-dense float arrays and is dramatically
         ;; faster than the portable Racket deflater.
         (define-values (process child-out child-in _child-error)
           (subprocess #f #f (current-error-port)
                       native-gzip "-1" "-n" "-c"))
         (define writer
           (thread
            (lambda ()
              (write-bytes bytes child-in)
              (close-output-port child-in))))
         (define compressed (port->bytes child-out))
         (close-input-port child-out)
         (thread-wait writer)
         (subprocess-wait process)
         (and (zero? (subprocess-status process)) compressed))))

(define (gzip-bytes/portable bytes)
  (define compressed (open-output-bytes))
  (gzip-through-ports (open-input-bytes bytes) compressed #f 0)
  (get-output-bytes compressed))

(define (gzip-base64 bytes)
  (bytes->string/utf-8
   (base64-encode
    (or (gzip-bytes/native bytes) (gzip-bytes/portable bytes)) #"")))

;; JSON lives in an HTML script element.  Escaping '<' prevents a model title
;; or other user-authored metadata from terminating that element with a literal
;; </script> sequence while remaining valid JSON for JSON.parse.
(define (json-script-text value)
  (define out (open-output-string))
  (write-json value out)
  (regexp-replace* #rx"<" (get-output-string out)
                   (lambda (_match) "\\u003c")))

(define (transform-point matrix point)
  (for/list ([row (in-list matrix)])
    (+ (for/sum ([coefficient (in-list (take row 3))]
                 [coordinate (in-list point)])
         (* coefficient coordinate))
       (fourth row))))

(define (stl-position-bytes path transform)
  (define bytes (file->bytes path))
  (unless (>= (bytes-length bytes) 84)
    (raise-user-error 'write-html-report "invalid binary STL: ~a" path))
  (define triangles (integer-bytes->integer bytes #f #f 80 84))
  (unless (= (bytes-length bytes) (+ 84 (* triangles 50)))
    (raise-user-error
     'write-html-report
     "Milestone 0 reports require binary STL geometry: ~a" path))
  (define out (open-output-bytes))
  (for* ([triangle (in-range triangles)]
         [vertex (in-range 3)])
    (define start (+ 84 (* triangle 50) 12 (* vertex 12)))
    (define point
      (for/list ([axis (in-range 3)])
        (floating-point-bytes->real bytes #f
                                    (+ start (* axis 4))
                                    (+ start (* (add1 axis) 4)))))
    (for ([coordinate (in-list (transform-point transform point))])
      (write-bytes (real->floating-point-bytes coordinate 4 #f) out)))
  (get-output-bytes out))

(define (sheet-position-bytes points local-to-solver solver-to-user)
  ;; The first report milestone uses the authored boundary as a triangle fan.
  ;; The production schema will consume the already-triangulated sheet export.
  (define transformed
    (for/list ([point (in-list points)])
      (transform-point
       solver-to-user
       (transform-point local-to-solver (list (first point) (second point) 0)))))
  (define out (open-output-bytes))
  (when (>= (length transformed) 3)
    (for ([index (in-range 1 (sub1 (length transformed)))])
      (for ([point (in-list
                    (list (first transformed)
                          (list-ref transformed index)
                          (list-ref transformed (add1 index))))])
        (for ([coordinate (in-list point)])
          (write-bytes (real->floating-point-bytes coordinate 4 #f) out)))))
  (get-output-bytes out))

(define (material-kind geometry)
  (hash-ref (hash-ref geometry 'material (hash)) 'kind "unknown"))

(define (geometry-style geometry)
  (case (string->symbol (material-kind geometry))
    [(pec) (values "#d8e9ff" #t 0.82)]
    [(conductor conducting-sheet) (values "#ffad38" #t 0.88)]
    [(dielectric) (values "#47c9d8" #f 0.28)]
    [else (values "#c561ff" #f 0.7)]))

(define (report-geometry root manifest)
  (define solver-to-user
    (hash-ref manifest 'solver_to_user_transform
              '((1 0 0 0) (0 1 0 0) (0 0 1 0))))
  (filter
   values
   (for/list ([geometry (in-list (hash-ref manifest 'geometry '()))]
              [geometry-index (in-naturals 1)])
     (define representation (hash-ref geometry 'representation ""))
     (define-values (color metal? opacity) (geometry-style geometry))
     (define positions
       (cond
         [(member representation
                  '("volume-stl" "rectilinear-conducting-boundary"
                    "pec-boundary-surfaces"))
          (define filename (hash-ref geometry 'file 'null))
          (and (string? filename)
               (stl-position-bytes (build-path root filename) solver-to-user))]
         [(string=? representation "planar-polygon")
          (sheet-position-bytes
           (hash-ref geometry 'points_2d '())
           (hash-ref geometry 'local_to_solver_transform)
           solver-to-user)]
         [else #f]))
     (and positions
          (hash 'index geometry-index
                'name (hash-ref geometry 'name "geometry")
                'representation representation
                'form (hash-ref geometry 'form "volume")
                'positions (gzip-base64 positions)
                'color color
                'metal metal?
                'opacity opacity)))))

(define (read-number-list path)
  (map string->number
       (filter (lambda (value) (not (string=? value "")))
               (regexp-split #px"[,[:space:]]+"
                             (string-trim (file->string path))))))

(define (capture-directory root manifest capture)
  (if (> (hash-ref manifest 'port_count 1) 1)
      (build-path root "simulation"
                  (format "excitation-~a"
                          (hash-ref capture 'excitation_index)))
      (build-path root "simulation")))

(define (report-captures root manifest)
  (define capture (hash-ref manifest 'field_capture (hash 'enabled #f)))
  (if (not (hash-ref capture 'enabled #f))
      (raise-user-error
       'write-html-report
       "the simulation did not record fields; add record-fields field-capture")
      (let ([directory (capture-directory root manifest capture)])
        (for/list ([dump (in-list (hash-ref capture 'dumps '()))])
          (define name (hash-ref dump 'name))
          (define shape-values
            (read-number-list (build-path directory (hash-ref dump 'shape))))
          (unless (and (= (length shape-values) 5)
                       (andmap number? shape-values))
            (raise-user-error 'write-html-report
                              "invalid normalized field shape for ~a" name))
          (hash
           'name name
           'label (format "~a — ~a"
                          (hash-ref dump 'quantity) (hash-ref dump 'source))
           'quantity (hash-ref dump 'quantity)
           'source (hash-ref dump 'source)
           'units (hash-ref dump 'units)
           'surface_reconstruction
           (hash-ref dump 'surface_reconstruction 'null)
           'frequency_mhz (/ (fifth shape-values) 1e6)
           'shape (map inexact->exact (take shape-values 4))
           'x (read-number-list
               (build-path directory (first (hash-ref dump 'axes))))
           'y (read-number-list
               (build-path directory (second (hash-ref dump 'axes))))
           'z (read-number-list
               (build-path directory (third (hash-ref dump 'axes))))
           'real (gzip-base64
                  (file->bytes
                   (build-path directory (hash-ref dump 'real_f32))))
           'imaginary (gzip-base64
                       (file->bytes
                        (build-path directory (hash-ref dump 'imag_f32)))))))))

(define (complex-report value)
  (hash 'real (exact->inexact (real-part value))
        'imaginary (exact->inexact (imag-part value))
        'magnitude (exact->inexact (magnitude value))
        'phase_degrees (exact->inexact (* 180 (/ (angle value) pi)))))

(define (port-sample-report port-name sample)
  (hash 'port (format "~a" port-name)
        'frequency_mhz (openems-port-sample-frequency-mhz sample)
        's11_db (openems-port-sample-s11-db sample)
        'reflection_coefficient
        (complex-report (openems-port-sample-reflection-coefficient sample))
        'impedance_ohms
        (complex-report (openems-port-sample-impedance sample))))

(define (result-measurements result)
  (cond
    [(openems-sweep-result? result)
     (hash
      'ports
      (list (hash 'name (format "~a" (openems-sweep-result-port-name result))
                  'reference_impedance_ohms
                  (openems-sweep-result-reference-impedance result)))
      'port_samples
      (map (lambda (sample)
             (port-sample-report (openems-sweep-result-port-name result) sample))
           (openems-sweep-result-samples result))
      's_parameters '())]
    [else
     (hash
      'ports
      (for/list ([port (in-list (openems-multiport-result-ports result))])
        (hash 'name (format "~a" (openems-result-port-name port))
              'reference_impedance_ohms
              (openems-result-port-reference-impedance port)))
      'port_samples
      (append*
       (for/list ([(port samples)
                   (in-hash (openems-multiport-result-input-samples result))])
         (map (lambda (sample) (port-sample-report port sample)) samples)))
      's_parameters
      (for/list ([sample
                  (in-list (openems-multiport-result-s-parameters result))])
        (hash 'frequency_mhz
              (openems-s-parameter-sample-frequency-mhz sample)
              'from (format "~a"
                            (openems-s-parameter-sample-input-port sample))
              'to (format "~a"
                          (openems-s-parameter-sample-output-port sample))
              'db (openems-s-parameter-sample-db sample)
              'value
              (complex-report (openems-s-parameter-sample-value sample)))))]))

(define (csv-number-rows path)
  (if (file-exists? path)
      (for/list ([line (in-list (file->lines path))]
                 #:unless (string=? (string-trim line) ""))
        (map string->number (string-split (string-trim line) ",")))
      '()))

(define (report-power-results root manifest)
  (define capture (hash-ref manifest 'field_capture (hash)))
  (define directory (capture-directory root manifest capture))
  (define port-rows (csv-number-rows (build-path directory "port-power.csv")))
  (define excitation (hash-ref capture 'excitation_index 1))
  (define incident-normalization
    (for/first ([row (in-list port-rows)]
                #:when (and (= (length row) 6)
                            (= (second row) excitation)
                            (= (third row) excitation)))
      (fourth row)))
  (define ports (hash-ref manifest 'ports '()))
  (define (normalized value)
    (if (and incident-normalization (> incident-normalization 0))
        (/ value incident-normalization)
        'null))
  (hash
   'normalization
   "absolute solver values plus ratios to selected excitation incident power"
   'incident_normalization_watts (or incident-normalization 'null)
   'ports
   (for/list ([row (in-list port-rows)] #:when (= (length row) 6))
     (define index (inexact->exact (round (second row))))
     (define accepted (sixth row))
     (hash 'frequency_mhz (/ (first row) 1e6)
           'port_index index
           'port
           (if (<= 1 index (length ports))
               (hash-ref (list-ref ports (sub1 index)) 'name (format "port-~a" index))
               (format "port-~a" index))
           'excitation_index (inexact->exact (round (third row)))
           'incident_watts (fourth row)
           'reflected_watts (fifth row)
           'accepted_watts accepted
           'incident_normalized (normalized (fourth row))
           'reflected_normalized (normalized (fifth row))
           'accepted_normalized (normalized accepted)
           'delivered_to_passive_port_normalized
           (if (= index excitation) 'null (normalized (- accepted)))))
   'dielectric
   (for/list ([row (in-list
                    (csv-number-rows
                     (build-path directory "dielectric-power.csv")))]
              #:when (= (length row) 3))
     (hash 'frequency_mhz (/ (first row) 1e6)
           'excitation_index (inexact->exact (round (second row)))
           'watts (third row)
           'normalized (normalized (third row))))
   'lumped
   (for/list ([row (in-list
                    (csv-number-rows
                     (build-path directory "lumped-power.csv")))]
              #:when (= (length row) 4))
     (hash 'frequency_mhz (/ (first row) 1e6)
           'component_index (inexact->exact (round (second row)))
           'excitation_index (inexact->exact (round (third row)))
           'watts (fourth row)
           'normalized (normalized (fourth row))))))

(define report-css #<<CSS
:root{color-scheme:dark;font-family:"DejaVu Sans Mono",ui-monospace,monospace;background:#030611;color:#d8fbff}*{box-sizing:border-box}body{margin:0;overflow:hidden;background:radial-gradient(circle at 65% 30%,#151037,#030611 55%)}header{position:fixed;z-index:3;left:18px;top:14px;text-shadow:0 0 12px #31efff}h1{margin:0;color:#7df9ff;font-size:20px;letter-spacing:.08em;text-transform:uppercase}#subtitle{margin-top:5px;color:#ff4bd8;font-size:12px}.panel{position:fixed;z-index:4;background:#07101ddd;border:1px solid #31efff88;box-shadow:0 0 22px #00d9ff2f,inset 0 0 18px #002a4133;padding:12px}#controls{left:18px;bottom:18px;width:min(480px,calc(100vw - 36px))}#metadata-panel{right:18px;top:18px;width:310px;max-height:42vh;overflow:auto}#metadata{white-space:pre-wrap;font-size:10px;color:#93b8c7;margin:0}label{font-size:11px;color:#89eeff}select,button,input{accent-color:#ff3bd4;background:#061322;color:#dff;border:1px solid #29e9ff;padding:5px}button{font-weight:bold;min-width:72px;box-shadow:0 0 10px #ff2fd655}.row{display:flex;align-items:center;gap:9px;margin-top:9px}.row[hidden]{display:none}.row input[type=range]{flex:1}.checks{margin-left:auto;display:flex;gap:9px}#capture{width:100%}#field-mode-row{display:grid;grid-template-columns:auto 54px auto minmax(0,1fr) auto 88px;gap:7px}#field-mode-row select{width:100%;min-width:0}#capture-detail{font-size:11px;color:#fff45c;margin-top:7px}#viewport{width:100vw;height:100vh;display:block}.scanlines{pointer-events:none;position:fixed;z-index:2;inset:0;background:repeating-linear-gradient(0deg,#0000 0,#0000 3px,#4ef1ff09 4px);mix-blend-mode:screen}@media(max-width:800px){#metadata-panel{display:none}}@media(max-width:520px){#field-mode-row{grid-template-columns:auto minmax(0,1fr)}}
CSS
  )

(define (write-html-report result destination #:title [title #f])
  (unless (path-string? destination)
    (raise-argument-error 'write-html-report "path-string?" destination))
  (define run (result-run result))
  (define artifacts (openems-run-info-artifacts run))
  (unless (openems-artifacts-available? artifacts)
    (raise-user-error 'write-html-report "the simulation artifacts are closed"))
  (define root (openems-artifacts-directory artifacts))
  (define manifest (openems-run-info-manifest run))
  (define mesh (hash-ref manifest 'mesh (hash)))
  (define mesh-axes
    (for/list ([axis (in-list '(x y z))])
      (hash-ref mesh axis '())))
  (define pml-cells 8)
  (define pml-available?
    (andmap (lambda (axis) (> (length axis) (* 2 pml-cells))) mesh-axes))
  (define report-data
    (hash
     'schema "antenna-turtle-report/m3"
     'user_to_solver_transform
     (hash-ref manifest 'user_to_solver_transform)
     'solver_to_user_transform
     (hash-ref manifest 'solver_to_user_transform)
     'pml
     (if pml-available?
         (hash 'enabled #t
               'cells pml-cells
               'inner_min (map (lambda (axis) (list-ref axis pml-cells)) mesh-axes)
               'inner_max
               (map (lambda (axis)
                      (list-ref axis (- (length axis) (add1 pml-cells))))
                    mesh-axes))
         (hash 'enabled #f))
     'metadata
     (hash 'title (or title (hash-ref manifest 'model_title "Antenna Turtle"))
           'subtitle
           (format "openEMS · ~a MHz field capture · portable report"
                   (hash-ref (hash-ref manifest 'field_capture) 'frequency_mhz))
           'model_frequency_mhz (hash-ref manifest 'model_frequency_mhz)
           'sweep (hash-ref manifest 'sweep)
           'field_capture (hash-ref manifest 'field_capture)
           'software_versions (hash-ref manifest 'software_versions (hash))
           'solver
           (hash 'status (hash-ref manifest 'status "unknown")
                 'elapsed_ms (openems-run-info-elapsed-ms run)
                 'exit_code (openems-run-info-exit-code run)
                 'statistics (hash-ref manifest 'solver_statistics (hash))
                 'excitation_statistics
                 (hash-ref manifest 'excitation_statistics '()))
           'mesh
           (let ([value (hash-ref manifest 'mesh (hash))])
             (hash 'cell_count (hash-ref value 'cell_count 'null)
                   'minimum_cell_spacing_m
                   (hash-ref value 'minimum_cell_spacing_m 'null)
                   'maximum_resolution_m
                   (hash-ref value 'maximum_resolution_m 'null)
                   'boundary_conditions
                   (hash-ref value 'boundary_conditions '())))
           'power_accounting (hash-ref manifest 'power_accounting (hash))
           'power_results (report-power-results root manifest)
           'nf2ff (hash-ref manifest 'nf2ff (hash))
           'measurements (result-measurements result))
     'geometry (report-geometry root manifest)
     'captures (report-captures root manifest)))
  (define complete (simplify-path (path->complete-path destination)))
  (make-parent-directory* complete)
  (call-with-output-file complete
    #:exists 'truncate/replace
    (lambda (out)
      (display "<!doctype html><html><head><meta charset=\"utf-8\">" out)
      (display "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" out)
      (display "<title>Antenna Turtle simulation report</title><style>" out)
      (display report-css out)
      (display "</style></head><body><header><h1 id=\"title\"></h1><div id=\"subtitle\"></div></header>" out)
      (display "<canvas id=\"viewport\"></canvas><div class=\"scanlines\"></div>" out)
      (display "<section class=\"panel\" id=\"controls\"><label for=\"capture\">LAYER / SLICE</label><select id=\"capture\"></select><div class=\"row\" id=\"current-mode-row\"><label for=\"current-mode\">COLOR</label><select id=\"current-mode\"><option value=\"magnitude\">|current|</option><option value=\"direction\">dir(current)</option><option value=\"charge\">charge</option><option value=\"combined\">charge + current</option></select></div><div id=\"field-controls\" hidden><div class=\"row\" id=\"volume-controls\" hidden><label for=\"slice-axis\">PLANE</label><select id=\"slice-axis\"><option value=\"x\">normal X</option><option value=\"y\">normal Y</option><option value=\"z\">normal Z</option></select><label for=\"slice-position\">POSITION <span id=\"slice-position-value\"></span></label><input id=\"slice-position\" type=\"range\" min=\"0\" max=\"1000\" step=\"1\" value=\"500\"></div><div class=\"row\" id=\"field-mode-row\"><label for=\"field-quantity\">FIELD</label><select id=\"field-quantity\"><option value=\"electric\">E</option><option value=\"magnetic\">H</option></select><label for=\"field-mode\">VIEW</label><select id=\"field-mode\"><option value=\"tangent-instantaneous\">instantaneous tangent intensity</option><option value=\"streamlines\">instantaneous field lines</option><option value=\"tangent-vectors\">tangent vectors</option><option value=\"tangent-magnitude\">tangent envelope (static)</option><option value=\"magnitude\">total envelope (static)</option><option value=\"normal\">normal component</option><option value=\"x\">x component</option><option value=\"y\">y component</option><option value=\"z\">z component</option><option value=\"vectors\">3D vectors</option></select><label for=\"field-range\">RANGE</label><select id=\"field-range\"><option value=\"slice\">slice auto</option><option value=\"volume\">volume</option></select></div><div class=\"row\"><label for=\"field-scale\">SCALE</label><select id=\"field-scale\"><option value=\"linear\">linear</option><option value=\"log\" selected>log</option></select><label for=\"log-floor\">FLOOR <span id=\"log-floor-value\">−40 dB</span></label><input id=\"log-floor\" type=\"range\" min=\"-80\" max=\"-10\" step=\"1\" value=\"-40\"></div><div class=\"row\"><label for=\"field-opacity\">OPACITY</label><input id=\"field-opacity\" type=\"range\" min=\"0.05\" max=\"1\" step=\"0.05\" value=\"0.8\"><label><input id=\"pml-visible\" type=\"checkbox\" checked> PML</label></div></div><div id=\"capture-detail\"></div><div class=\"row\"><button id=\"play\">PAUSE</button><label>PHASE <span id=\"phase-value\">0°</span></label><input id=\"phase\" type=\"range\" min=\"0\" max=\"360\" value=\"0\"></div><div class=\"row\"><label>SPEED <span id=\"speed-value\">1.00×</span></label><input id=\"speed\" type=\"range\" min=\"0.1\" max=\"4\" step=\"0.05\" value=\"1\"><span class=\"checks\"><label><input id=\"model-visible\" type=\"checkbox\" checked> MODEL</label><label><input id=\"field-visible\" type=\"checkbox\" checked> FIELD</label></span></div></section>" out)
      (display "<details class=\"panel\" id=\"metadata-panel\"><summary>SIMULATION METADATA</summary><pre id=\"metadata\"></pre></details>" out)
      (display "<script type=\"application/json\" id=\"antenna-turtle-report-data\">" out)
      (display (json-script-text report-data) out)
      (display "</script><script>" out)
      (display (file->string viewer-bundle) out)
      (display "</script></body></html>" out)))
  complete)
