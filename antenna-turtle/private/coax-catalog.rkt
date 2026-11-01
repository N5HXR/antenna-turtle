#lang racket/base

(require "core.rkt")

(provide
 (struct-out coax-spec)
 coax-spec-ref
 known-coax-types)

;; Nominal data-sheet values.  Coax families, particularly RG-8X and RG-58,
;; are made by many vendors, so a model may override any of these values.
(struct coax-spec (name impedance velocity-factor diameter color input-gap)
  #:transparent)

(define (spec name impedance velocity-factor diameter)
  ;; The input gap is model geometry, rather than a cable data-sheet value.
  ;; One centimetre is a useful default for the generated one-segment port.
  (coax-spec name impedance velocity-factor diameter "purple" centimeter))

(define coax-specifications
  (list
   (spec 'rg58   50 .66 (* .195 inch))
   (spec 'rg6    75 .82 (* .275 inch))
   (spec 'rg8    50 .66 (* .405 inch))
   (spec 'rg8x   50 .78 (* .242 inch))
   (spec 'rg213  50 .66 (* .405 inch))
   (spec 'rg174  50 .66 (* .110 inch))
   (spec 'rg316  50 .70 (* .098 inch))
   (spec 'rg400  50 .70 (* .195 inch))
   (spec 'rg142  50 .70 (* .195 inch))
   (spec 'rg402  50 .69 (* .141 inch))
   (spec 'rg405  50 .69 (* .086 inch))
   (spec 'lmr195 50 .83 (* .195 inch))
   (spec 'lmr240 50 .84 (* .240 inch))
   (spec 'lmr400 50 .85 (* .405 inch))
   (spec 'lmr600 50 .87 (* .590 inch))))

(define known-coax-types
  (map coax-spec-name coax-specifications))

(define coax-spec-by-name
  (for/hash ([entry (in-list coax-specifications)])
    (values (coax-spec-name entry) entry)))

(define (coax-spec-ref name)
  (define normalized
    (cond [(symbol? name) (string->symbol (string-downcase (symbol->string name)))]
          [(string? name) (string->symbol (string-downcase name))]
          [else name]))
  (hash-ref coax-spec-by-name normalized
            (lambda ()
              (raise-arguments-error
               'coax "unknown coax type"
               "type" name
               "known types" known-coax-types))))
