#lang racket/base

(require json
         racket/file
         racket/format
         racket/list
         racket/math
         racket/path
         racket/runtime-path
         racket/string
         "core.rkt"
         "nec2c.rkt")

(provide write-nec2c-html-report)

(define-runtime-path viewer-bundle "report-assets/viewer.bundle.js")

(define (json-script-text value)
  (define out (open-output-string))
  (write-json value out)
  (regexp-replace* #rx"<" (get-output-string out)
                   (lambda (_match) "\\u003c")))

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

(define (feed-report edge)
  (and (wire-edge-feed? edge)
       (hash 'name (format "~a" (wire-edge-feed-name edge))
             'fraction (if (eq? (wire-edge-feed-location edge) 'center) 0.5 1.0)
             'amplitude (wire-edge-feed-amplitude edge)
             'phase_degrees (wire-edge-feed-phase edge))))

(define (geometry-report)
  (hash
   'grounded (model-grounded?)
   'wires
   (for/list ([edge (in-list (model-edges))])
     (hash 'id (wire-edge-id edge)
           'start (point-report (vertex-point (wire-edge-start edge)))
           'end (point-report (vertex-point (wire-edge-end edge)))
           'diameter (exact->inexact (wire-edge-diameter edge))
           'feed (or (feed-report edge) 'null)))))

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
        'polarization
        (let ([sense (nec2c-pattern-sample-polarization-sense sample)])
          (if sense (format "~a" sense) 'null))))

(define (pattern-report pattern)
  (hash 'frequency_mhz (exact->inexact (or (pattern-frequency pattern) (model-frequency)))
        'theta_values (map exact->inexact (nec2c-pattern-grid-theta-values pattern))
        'phi_values (map exact->inexact (nec2c-pattern-grid-phi-values pattern))
        'samples (map pattern-sample-report (nec2c-pattern-grid-samples pattern))))

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
  (define measurements
    (if (nec2c-sweep-result? result)
        (sweep-measurements result)
        (gain-sweep-measurements result)))
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
     'pattern (pattern-report pattern)))
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
      (display (json-script-text report-data) out)
      (display "</script><script>" out)
      (display (file->string viewer-bundle) out)
      (display "</script></body></html>" out)))
  complete)
