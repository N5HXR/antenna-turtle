#lang racket/base

(require racket/cmdline
         racket/list
         "build.rkt")

(define (show-top-level-help)
  (displayln "usage: raco antenna-turtle build [options] model.rkt")
  (displayln "")
  (displayln "Build and preview antenna-turtle models."))

(define arguments (vector->list (current-command-line-arguments)))

;; `racket/cmdline` normally stops recognizing switches at the first positional
;; argument. Build commands read more naturally with the model either first or
;; last, so move the known switches (and the output-directory value) ahead of
;; positional arguments before handing them to `command-line`.
(define (normalize-build-arguments arguments)
  (define switches-with-values '("-o" "--output-dir"))
  (define switches-without-values
    '("--nec2c" "--mmana" "--matlab" "--matlab-loft"
      "--matlab-ribbon" "--all" "--view" "-h" "--help"))
  (let loop ([remaining arguments] [switches '()] [positionals '()])
    (cond
      [(null? remaining) (append (reverse switches) (reverse positionals))]
      [(member (car remaining) switches-with-values)
       (if (null? (cdr remaining))
           ;; Leave the incomplete switch for command-line's normal error.
           (loop (cdr remaining) (cons (car remaining) switches) positionals)
           (loop (cddr remaining)
                 (cons (cadr remaining) (cons (car remaining) switches))
                 positionals))]
      [(member (car remaining) switches-without-values)
       (loop (cdr remaining) (cons (car remaining) switches) positionals)]
      [else
       (loop (cdr remaining) switches (cons (car remaining) positionals))])))

(cond
  [(or (null? arguments)
       (member (car arguments) '("-h" "--help")))
   (show-top-level-help)]
  [(not (string=? (car arguments) "build"))
   (raise-user-error 'raco-antenna-turtle
                     "expected subcommand `build`; received ~a"
                     (car arguments))]
  [else
   (define nec2c? #f)
   (define mmana? #f)
   (define matlab? #f)
   (define matlab-ribbon? #f)
   (define all? #f)
   (define view? #f)
   (define output-directory #f)
   (define model-file
     (parameterize ([current-command-line-arguments
                     (list->vector
                      (normalize-build-arguments (cdr arguments)))])
       (command-line
        #:program "raco antenna-turtle build"
        #:once-each
        [("--nec2c") "Generate a NEC2C .nec file" (set! nec2c? #t)]
        [("--mmana") "Generate an MMANA-GAL .maa file" (set! mmana? #t)]
        [("--matlab" "--matlab-loft")
         "Generate the preferred loft MATLAB .m file"
         (set! matlab? #t)]
        [("--matlab-ribbon")
         "Generate the approximate ribbon MATLAB .m file"
         (set! matlab-ribbon? #t)]
        [("--all") "Generate every supported representation" (set! all? #t)]
        [("--view") "Open an interactive 3-D geometry preview"
         (set! view? #t)]
        [("-o" "--output-dir") directory
         "Write generated files to <directory>"
         (set! output-directory directory)]
        #:args (model-file)
        model-file)))
   (define selected-formats
     (cond
       [all? supported-build-formats]
       [(or nec2c? mmana? matlab? matlab-ribbon?)
        (filter values
                (list (and nec2c? 'nec2c)
                      (and mmana? 'mmana)
                      (and matlab? 'matlab)
                      (and matlab-ribbon? 'matlab-ribbon)))]
       [else default-build-formats]))
   (for ([output-path
          (in-list
           (build-model model-file
                        #:output-directory output-directory
                        #:formats selected-formats
                        #:view? view?))])
     (printf "generated ~a\n" output-path))])
