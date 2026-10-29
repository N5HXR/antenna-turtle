#lang racket/base

(provide
 (struct-out nec2c-capability-set)
 parse-nec2c-capabilities-jsexpr
 nec2c-capability-supports?)

(struct nec2c-capability-set
  (program program-version schema-version dielectric-feature-revision
           dielectric-resource-versions result-json-versions validate-only?
           legacy-result-output? solvers grounds limits raw)
  #:transparent)

(define (fail message . fields)
  (apply raise-arguments-error 'parse-nec2c-capabilities-jsexpr message fields))

(define (required object key context)
  (unless (hash? object) (fail (format "~a must be an object" context) "value" object))
  (hash-ref object key
            (lambda () (fail (format "~a is missing a required field" context)
                             "field" key))))

(define (typed predicate expected value context)
  (unless (predicate value)
    (fail (format "~a has the wrong type" context)
          "expected" expected "value" value))
  value)

(define (list-of? predicate value)
  (and (list? value) (andmap predicate value)))

(define (parse-nec2c-capabilities-jsexpr document)
  (typed hash? "object" document "capability document")
  (unless (equal? (required document 'schema "capability document")
                  "nec2c-capabilities")
    (fail "unknown capability schema"
          "schema" (required document 'schema "capability document")))
  (define schema-version
    (required document 'schema_version "capability document"))
  (unless (equal? schema-version 1)
    (fail "unknown capability schema version" "schema_version" schema-version))
  (define features
    (typed hash? "object" (required document 'features "capability document")
           "features"))
  (define (feature-list key predicate expected)
    (typed (lambda (value) (list-of? predicate value)) expected
           (required features key "features") (format "features.~a" key)))
  (nec2c-capability-set
   (typed string? "string?" (required document 'program "capability document")
          "program")
   (typed string? "string?"
          (required document 'program_version "capability document")
          "program_version")
   schema-version
   (typed exact-nonnegative-integer? "exact-nonnegative-integer?"
          (required features 'dielectric_feature_revision "features")
          "features.dielectric_feature_revision")
   (feature-list 'dielectric_resource_versions exact-positive-integer?
                 "list of positive integers")
   (feature-list 'result_json_versions exact-positive-integer?
                 "list of positive integers")
   (typed boolean? "boolean?" (required features 'validate_only "features")
          "features.validate_only")
   (typed boolean? "boolean?"
          (required features 'legacy_result_output "features")
          "features.legacy_result_output")
   (feature-list 'solvers string? "list of strings")
   (feature-list 'grounds string? "list of strings")
   (typed hash? "object" (required document 'limits "capability document")
          "limits")
   document))

(define (nec2c-capability-supports? capabilities feature value)
  (unless (nec2c-capability-set? capabilities)
    (raise-argument-error
     'nec2c-capability-supports? "nec2c-capability-set?" capabilities))
  (case feature
    [(dielectric-resource-version)
     (and (member value
                  (nec2c-capability-set-dielectric-resource-versions capabilities))
          #t)]
    [(result-json-version)
     (and (member value (nec2c-capability-set-result-json-versions capabilities)) #t)]
    [(solver)
     (and (member (if (symbol? value) (symbol->string value) value)
                  (nec2c-capability-set-solvers capabilities)) #t)]
    [(ground)
     (and (member (if (symbol? value) (symbol->string value) value)
                  (nec2c-capability-set-grounds capabilities)) #t)]
    [else
     (raise-argument-error
      'nec2c-capability-supports?
      "(or/c 'dielectric-resource-version 'result-json-version 'solver 'ground)"
      feature)]))
