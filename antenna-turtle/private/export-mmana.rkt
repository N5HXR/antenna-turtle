#lang racket/base

(require racket/file
         "core.rkt"
         "export-common.rkt")

(provide export-mmana)

(define (pcoord who point accessor)
  (coordinate-string who (accessor point)))

;; MMANA owns the calculation settings beginning with its global segmentation
;; section. Antenna Turtle owns everything before it: title, frequency, wires,
;; sources, and loads. Keeping the suffix byte-for-byte also avoids changing
;; MMANA's line endings or any target-specific data added by a newer version.
(define mmana-section-patterns
  (list
   (cons 'wires
         #px#"(?im:^\\*+[^\r\n]*wires?[^\r\n]*\r?$)")
   (cons 'sources
         #px#"(?im:^\\*+[^\r\n]*sources?[^\r\n]*\r?$)")
   (cons 'loads
         #px#"(?im:^\\*+[^\r\n]*loads?[^\r\n]*\r?$)")
   (cons 'segmentation
         #px#"(?im:^\\*+[^\r\n]*segmentation[^\r\n]*\r?$)")
   (cons 'calculation-settings
         #px#"(?im:^\\*+[^\r\n]*G/H/[^\r\n]*\r?$)")))

(define (existing-calculation-suffix who content)
  (define positions
    (for/list ([section (in-list mmana-section-patterns)])
      (define match (regexp-match-positions (cdr section) content))
      (unless match
        (error who
               (string-append
                "existing MMANA file is not recognizable: missing "
                "~a section; original file was not modified")
               (car section)))
      (cons (car section) (caar match))))
  (for ([earlier (in-list positions)]
        [later (in-list (cdr positions))])
    (unless (< (cdr earlier) (cdr later))
      (error who
             (string-append
              "existing MMANA sections are out of order near ~a and ~a; "
              "original file was not modified")
             (car earlier)
             (car later))))
  (subbytes content (cdr (assq 'segmentation positions))))

(define (managed-prefix who max-length feeds)
  (define out (open-output-string))
  (fprintf out "~a\n" (model-title))
  (fprintf out "*\n")
  (fprintf out "~a\n" (coordinate-string who (model-frequency)))
  (fprintf out "* Wires *\n")
  (fprintf out "~a\n" (length (model-edges)))
  (for ([edge (in-list (model-edges))])
    (define a (vertex-point (wire-edge-start edge)))
    (define b (vertex-point (wire-edge-end edge)))
    (fprintf out "~a,\t~a,\t~a,\t~a,\t~a,\t~a,\t~a,\t~a\n"
             (pcoord who a point3-x)
             (pcoord who a point3-y)
             (pcoord who a point3-z)
             (pcoord who b point3-x)
             (pcoord who b point3-y)
             (pcoord who b point3-z)
             (coordinate-string who (/ (wire-edge-diameter edge) 2))
             (edge-segment-count edge max-length)))
  (fprintf out "*** Sources ***\n")
  (fprintf out "~a,\t1\n" (length feeds))
  (for ([edge (in-list feeds)])
    ;; MMANA names sources by wire and beginning/center/end position.
    (define suffix
      (case (wire-edge-feed-location edge)
        [(start) "b"]
        [(center) "c"]
        [(end) "e"]))
    (fprintf out "w~a~a,\t0.0,\t1.0\n" (wire-edge-id edge) suffix))
  ;; Loads are intentionally Antenna Turtle-owned for now. This clears manual
  ;; MMANA loads rather than risking stale wire references after regeneration.
  (fprintf out "*** Loads ***\n")
  (fprintf out "0,\t0\n")
  (get-output-bytes out))

(define default-calculation-suffix
  (string->bytes/utf-8
   (string-append
    "*** Segmentation ***\n"
    "400,\t80,\t2.0,\t1\n"
    "*G/H/M/R/AzEl/X*\n"
    ;; Free space, with remaining values chosen from MMANA's stock files.
    "0,\t0.0,\t1,\t50.0,\t120,\t60,\t0\n")))

(define (uses-crlf? content)
  (regexp-match? #rx#"\r\n" content))

(define (adapt-line-endings content crlf?)
  (if crlf?
      (regexp-replace* #rx#"\n" content #"\r\n")
      content))

(define (export-mmana path)
  (validate-model!)
  (define who 'export-mmana)
  (define max-length (require-segmentation! who))
  (define frequency (model-frequency))
  (unless (and (real? frequency) (> frequency 0))
    (error who "model-frequency must be a positive MHz value"))
  (define feeds (filter wire-edge-feed? (model-edges)))
  (define old-content (and (file-exists? path) (file->bytes path)))
  ;; Parse before opening any output port. A malformed existing target must be
  ;; left completely untouched.
  (define calculation-suffix
    (if old-content
        (existing-calculation-suffix who old-content)
        default-calculation-suffix))
  (define crlf? (and old-content (uses-crlf? old-content)))
  (define new-content
    (bytes-append
     (adapt-line-endings (managed-prefix who max-length feeds) crlf?)
     calculation-suffix))
  (call-with-atomic-output-file
   path
   (lambda (out temporary-path)
     (write-bytes new-content out)))
  path)
