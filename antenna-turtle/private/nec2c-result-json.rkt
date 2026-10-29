#lang racket/base

(require json
         racket/list
         racket/port)

(provide
 (struct-out nec2c-result-producer)
 (struct-out nec2c-result-diagnostic)
 (struct-out nec2c-result-rows)
 (struct-out nec2c-result-execution)
 (struct-out nec2c-result-job)
 (struct-out nec2c-machine-result)
 read-nec2c-result-json
 parse-nec2c-result-jsexpr
 nec2c-result-json-null?
 nec2c-result-row-ref)

(struct nec2c-result-producer
  (program program-version dielectric-feature-revision raw)
  #:transparent)
(struct nec2c-result-diagnostic (severity code message context raw)
  #:transparent)
(struct nec2c-result-rows (units columns rows raw)
  #:transparent)
(struct nec2c-result-execution
  (execution-index status frequency-mhz mesh-state-id ground-state-id
                   excitation trigger solver
                   material-evaluations feeds wire-currents patch-currents
                   volume-currents power far-fields near-fields raw)
  #:transparent)
(struct nec2c-result-job
  (job-index dielectric mesh-states ground-states executions
             omitted-requests validation raw)
  #:transparent)
(struct nec2c-machine-result
  (producer input jobs diagnostics completion-status raw)
  #:transparent)

(define (nec2c-result-json-null? value)
  (eq? value (json-null)))

(define (contract-error message . fields)
  (apply raise-arguments-error 'read-nec2c-result-json message fields))

(define (object-value object key [context "JSON object"])
  (unless (hash? object)
    (contract-error (format "~a must be an object" context) "value" object))
  (hash-ref
   object key
   (lambda ()
     (contract-error (format "~a is missing required field" context)
                     "field" key))))

(define (optional-value object key [default #f])
  (hash-ref object key (lambda () default)))

(define (require-type predicate expected value context)
  (unless (predicate value)
    (contract-error (format "~a has the wrong type" context)
                    "expected" expected "value" value))
  value)

(define (require-member value choices context)
  (unless (member value choices)
    (contract-error (format "~a has an unknown value" context)
                    "allowed" choices "value" value))
  value)

(define (parse-producer value)
  (define context "producer")
  (nec2c-result-producer
   (require-type string? "string?" (object-value value 'program context)
                 "producer.program")
   (require-type string? "string?" (object-value value 'program_version context)
                 "producer.program_version")
   (require-type exact-nonnegative-integer?
                 "exact-nonnegative-integer?"
                 (object-value value 'dielectric_feature_revision context)
                 "producer.dielectric_feature_revision")
   value))

(define (parse-diagnostic value)
  (define severity
    (require-member (object-value value 'severity "diagnostic")
                    '("warning" "error") "diagnostic.severity"))
  (nec2c-result-diagnostic
   severity
   (require-type string? "string?" (object-value value 'code "diagnostic")
                 "diagnostic.code")
   (require-type string? "string?" (object-value value 'message "diagnostic")
                 "diagnostic.message")
   (require-type hash? "object" (object-value value 'context "diagnostic")
                 "diagnostic.context")
   value))

(define (parse-rows value context #:nullable? [nullable? #f])
  (cond
    [(and nullable? (nec2c-result-json-null? value)) value]
    [else
     (require-type hash? "object" value context)
     (unless (equal? (object-value value 'encoding context) "rows-v1")
       (contract-error (format "~a uses an unknown row encoding" context)
                       "encoding" (object-value value 'encoding context)))
     (define columns
       (require-type list? "array" (object-value value 'columns context)
                     (string-append context ".columns")))
     (unless (andmap string? columns)
       (contract-error (format "~a column names must be strings" context)
                       "columns" columns))
     (when (check-duplicates columns)
       (contract-error (format "~a column names must be unique" context)
                       "columns" columns))
     (define rows
       (require-type list? "array" (object-value value 'rows context)
                     (string-append context ".rows")))
     (for ([row (in-list rows)] [index (in-naturals)])
       (unless (and (list? row) (= (length row) (length columns)))
         (contract-error (format "~a row width does not match columns" context)
                         "row index" index "row" row "columns" columns)))
     (nec2c-result-rows (optional-value value 'units #f) columns rows value)]))

(define (parse-execution value)
  (define context "execution")
  (define status
    (require-member (object-value value 'status context)
                    '("ok" "failed") "execution.status"))
  (define excitation (object-value value 'excitation context))
  (require-member (object-value excitation 'kind "execution.excitation")
                  '("driven-voltage" "plane-wave")
                  "execution.excitation.kind")
  (unless (equal? (object-value excitation 'phasor_convention
                                "execution.excitation")
                  "exp(+i omega t)")
    (contract-error "execution has an unsupported phasor convention"
                    "value" (object-value excitation 'phasor_convention
                                          "execution.excitation")))
  (define trigger (object-value value 'trigger context))
  (require-member (object-value trigger 'kind "execution.trigger")
                  '("XQ" "RP" "NE" "NH" "EN")
                  "execution.trigger.kind")
  (define solver (object-value value 'solver context))
  ;; A failed execution can terminate before a solver is selected, in which
  ;; case schema v1 deliberately reports JSON null. Successful executions
  ;; must always identify the requested and realized solver.
  (unless (and (equal? status "failed")
               (nec2c-result-json-null? solver))
    (require-type hash? "object" solver "execution.solver")
    (for ([key '(requested used)])
      (require-member (object-value solver key "execution.solver")
                      '("legacy-nec-direct" "dense" "gmres" "fft")
                      (format "execution.solver.~a" key))))
  (define (successful-section key [parser values] #:nullable? [nullable? #f])
    (cond
      [(equal? status "failed")
       (optional-value value key #f)]
      [else
       (define section (object-value value key context))
       (if (and nullable? (nec2c-result-json-null? section))
           section
           (parser section))]))
  (define (array-section key)
    (successful-section
     key (lambda (section)
           (require-type list? "array" section (format "execution.~a" key)))))
  (nec2c-result-execution
   (require-type exact-nonnegative-integer? "exact-nonnegative-integer?"
                 (object-value value 'execution_index context)
                 "execution.execution_index")
   status
   (require-type real? "real?" (object-value value 'frequency_mhz context)
                 "execution.frequency_mhz")
   (object-value value 'mesh_state_id context)
   (object-value value 'ground_state_id context)
   excitation trigger solver
   (array-section 'material_evaluations)
   (array-section 'feeds)
   (array-section 'wire_currents)
   (successful-section 'patch_currents
                       (lambda (section)
                         (parse-rows section "execution.patch_currents")))
   (successful-section 'volume_currents
                       (lambda (section)
                         (parse-rows section "execution.volume_currents"))
                       #:nullable? #t)
   (successful-section 'power values #:nullable? #t)
   (array-section 'far_fields)
   (array-section 'near_fields)
   value))

(define (parse-job value)
  (define context "job")
  (define executions
    (require-type list? "array" (object-value value 'executions context)
                  "job.executions"))
  (nec2c-result-job
   (require-type exact-nonnegative-integer? "exact-nonnegative-integer?"
                 (object-value value 'job_index context) "job.job_index")
   (object-value value 'dielectric context)
   (require-type list? "array" (object-value value 'mesh_states context)
                 "job.mesh_states")
   (require-type list? "array" (object-value value 'ground_states context)
                 "job.ground_states")
   (map parse-execution executions)
   (require-type list? "array" (object-value value 'omitted_requests context)
                 "job.omitted_requests")
   (let ([validation (optional-value value 'validation #f)])
     (when validation
       (require-member validation '("classic-input-only" "dielectric-preflight")
                       "job.validation"))
     validation)
   value))

(define (parse-nec2c-result-jsexpr document)
  (require-type hash? "object" document "result document")
  (unless (equal? (object-value document 'schema "result document")
                  "nec2c-results")
    (contract-error "unknown result schema"
                    "schema" (object-value document 'schema "result document")))
  (unless (= (object-value document 'schema_version "result document") 1)
    (contract-error "unknown result schema version"
                    "schema_version"
                    (object-value document 'schema_version "result document")))
  (define completion (object-value document 'completion "result document"))
  (define completion-status
    (require-member
     (object-value completion 'status "completion")
     '("ok" "validation-error" "solver-error" "internal-error")
     "completion.status"))
  (nec2c-machine-result
   (parse-producer (object-value document 'producer "result document"))
   (require-type hash? "object" (object-value document 'input "result document")
                 "input")
   (map parse-job
        (require-type list? "array" (object-value document 'jobs "result document")
                      "jobs"))
   (map parse-diagnostic
        (require-type list? "array"
                      (object-value document 'diagnostics "result document")
                      "diagnostics"))
   completion-status
   document))

(define (read-nec2c-result-json source)
  (define document
    (cond
      [(input-port? source) (read-json source)]
      [(path-string? source)
       (call-with-input-file source read-json)]
      [else
       (raise-argument-error
        'read-nec2c-result-json "(or/c input-port? path-string?)" source)]))
  (parse-nec2c-result-jsexpr document))

(define (nec2c-result-row-ref rows row column)
  (unless (nec2c-result-rows? rows)
    (raise-argument-error 'nec2c-result-row-ref "nec2c-result-rows?" rows))
  (unless (and (list? row) (= (length row) (length (nec2c-result-rows-columns rows))))
    (raise-argument-error 'nec2c-result-row-ref "row from the rows-v1 dataset" row))
  (unless (string? column)
    (raise-argument-error 'nec2c-result-row-ref "string?" column))
  (define index (index-of (nec2c-result-rows-columns rows) column))
  (unless index
    (raise-arguments-error 'nec2c-result-row-ref
                           "column is not present"
                           "column" column
                           "available columns" (nec2c-result-rows-columns rows)))
  (list-ref row index))
