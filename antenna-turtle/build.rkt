#lang racket/base

(require racket/file
         racket/list
         racket/path
         "private/core.rkt"
         "private/export-nec2c.rkt"
         "private/export-mmana.rkt"
         "private/export-matlab.rkt"
         "private/export-matlab-loft.rkt")

(provide build-model default-build-formats supported-build-formats)

(define default-build-formats '(nec2c mmana matlab))
(define supported-build-formats '(nec2c mmana matlab matlab-ribbon))

(define (format-output-path output-directory stem format formats)
  (define filename
    (case format
      [(nec2c) (string-append stem ".nec")]
      [(mmana) (string-append stem ".maa")]
      [(matlab) (string-append stem ".m")]
      [(matlab-ribbon)
       ;; When both MATLAB representations are requested, reserve the plain
       ;; .m name for the preferred loft representation.
       (string-append stem
                      (if (member 'matlab formats) "-ribbon" "")
                      ".m")]))
  (build-path output-directory filename))

(define (build-model source-path
                     #:output-directory [requested-output-directory #f]
                     #:formats [requested-formats default-build-formats])
  (define source
    (simplify-path (path->complete-path source-path)))
  (unless (file-exists? source)
    (raise-user-error 'antenna-turtle-build
                      "model source does not exist: ~a"
                      source))
  (define formats (remove-duplicates requested-formats))
  (for ([format (in-list formats)])
    (unless (member format supported-build-formats)
      (raise-arguments-error 'build-model
                             "unsupported output format"
                             "format" format
                             "supported" supported-build-formats)))
  (when (null? formats)
    (raise-arguments-error 'build-model "at least one output format is required"))

  ;; Evaluating an antenna-turtle module resets, constructs, and validates the
  ;; shared model. Explicit export calls in the source still run normally.
  (dynamic-require source #f)

  (define source-directory (or (path-only source) (current-directory)))
  (define output-directory
    (simplify-path
     (path->complete-path (or requested-output-directory source-directory))))
  (make-directory* output-directory)
  (define stem
    (path->string
     (path-replace-extension (file-name-from-path source) #"")))

  (for/list ([format (in-list formats)])
    (define output-path
      (format-output-path output-directory stem format formats))
    (case format
      [(nec2c) (export-nec2c output-path)]
      [(mmana) (export-mmana output-path)]
      [(matlab) (export-matlab-loft output-path)]
      [(matlab-ribbon) (export-matlab output-path)])
    output-path))
