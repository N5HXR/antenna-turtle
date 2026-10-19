#lang racket

(require (except-in "private/core.rkt" feed cylinder scale)
         "private/electrical-units.rkt"
         "private/export-nec2c.rkt"
         "private/export-mmana.rkt"
         "private/export-matlab.rkt"
         "private/export-matlab-loft.rkt"
         "private/nec2c.rkt"
         "private/nec2c-html-report.rkt"
         "private/nec2c-view.rkt"
         "private/view.rkt"
         k-infix
         (planet jphelps/loop:1:25)
         (for-syntax racket/base
                     racket/list
                     racket/syntax
                     syntax/parse))

;; Manifold is an optional native dependency. Probe it while compiling the
;; language so a minimal installation can still load the wire DSL and pure
;; file exporters. The resulting choice is recorded in main.zo; installing or
;; repairing Manifold later therefore requires `raco setup antenna-turtle` to
;; rebuild this module. Backend names are deliberately
;; absent, rather than stubbed, in the minimal language so Racket reports its
;; ordinary unbound-identifier diagnostic when a solid model is attempted.
(begin-for-syntax
  (define solid-backend-load-failure
    (with-handlers ([exn:fail? values])
      (dynamic-require 'manifold #f)
      #f)))

(define validate-enabled-scenes! void)

(define-syntax (include-optional-solid-backend stx)
  (if solid-backend-load-failure
      #'(begin
          (eprintf
           (string-append
            "Antenna Turtle: Manifold unavailable; solid/OpenEMS support "
            "disabled.\n")))
      #'(begin
          (require (except-in "private/solid-core.rkt" dielectric conductor)
                   "private/solid-dsl.rkt"
                   "private/solid-trace-dsl.rkt"
                   "private/solid-primitives.rkt"
                   "private/material-catalog.rkt"
                   "private/simulation-profile.rkt"
                   "private/simulation-dsl.rkt"
                   "private/field-capture.rkt"
                   "private/nec2c-surface.rkt"
                   "private/html-report.rkt"
                   "private/solid-view.rkt"
                   "private/openems.rkt"
                   "private/openems-power.rkt"
                   "private/measurement.rkt")
          (provide
           (all-from-out "private/solid-core.rkt")
           (all-from-out "private/solid-dsl.rkt")
           (all-from-out "private/solid-trace-dsl.rkt")
           (all-from-out "private/solid-primitives.rkt")
           (all-from-out "private/material-catalog.rkt")
           (all-from-out "private/simulation-profile.rkt")
           (all-from-out "private/simulation-dsl.rkt")
           (all-from-out "private/field-capture.rkt")
           (all-from-out "private/nec2c-surface.rkt")
           (all-from-out "private/html-report.rkt")
           (all-from-out "private/openems.rkt")
           (all-from-out "private/openems-power.rkt")
           (all-from-out "private/measurement.rkt")
           show-solid-model)
          (set! validate-enabled-scenes! validate-solid-scene!))))

(include-optional-solid-backend)

(provide
 (except-out (all-from-out racket) #%module-begin)
 (rename-out [antenna-module-begin #%module-begin])
 #%braces
 (all-from-out (planet jphelps/loop:1:25))
 (all-from-out "private/nec2c.rkt")
 (all-from-out "private/nec2c-html-report.rkt")
 (all-from-out "private/nec2c-view.rkt")
 (all-from-out "private/electrical-units.rkt")
 wavelength
 half-wave
 quarter-wave
 radial-iterations
 (except-out (all-from-out "private/core.rkt")
             move-local move-vector-local move-vector-local-steps
             point-vector-local spread-local
             mark-feed
             call-with-wire call-with-points call-with-scale call-from-here
             call-with-warp call-with-surface call-with-reflection
             call-with-radial-repeat radial-iterations-value
             register-model-reset-hook! current-turtle-affine-transform
             current-turtle-event-handler current-wire-active?
             call-with-pen call-with-push)
 model
 turn
 move
 point
 spread
 feed
 reflect
 radial-repeat
 with-wire
 with-points
 from-here
 with-warp
 with-surface
 ;; Compatibility forms retained for existing models.
 with-pen
 with-scale
 with-push
 export-nec2c
 export-mmana
 export-matlab
 export-matlab-loft
 show-model)

;; The language reader tags {...} as (#%braces ...). Delegate those tokens to
;; k-infix while retaining the lexical context of identifiers inside the form.
(define-syntax-rule (#%braces token ...)
  ($ token ...))

;; These read like global geometry constants, but deliberately resolve at each
;; use so reset-model! and iterative generators always see the current model
;; frequency rather than a value captured when the module was initialized.
(define-syntax wavelength
  (syntax-id-rules ()
    [wavelength (model-wavelength)]))

(define-syntax half-wave
  (syntax-id-rules ()
    [half-wave (/ (model-wavelength) 2)]))

(define-syntax quarter-wave
  (syntax-id-rules ()
    [quarter-wave (/ (model-wavelength) 4)]))

(define-syntax radial-iterations
  (syntax-id-rules ()
    [radial-iterations (radial-iterations-value)]))

(define-syntax (antenna-module-begin stx)
  (syntax-case stx ()
    [(_ form ...)
     #'(#%plain-module-begin
        (reset-model!)
        form ...
        (validate-model!)
        (validate-enabled-scenes!))]))

(begin-for-syntax
  (define (syntax-pairs who stx description)
    (define items (cdr (syntax->list stx)))
    (when (or (null? items) (odd? (length items)))
      (raise-syntax-error who description stx))
    (for/list ([offset (in-range 0 (length items) 2)])
      (define key (list-ref items offset))
      (unless (identifier? key)
        (raise-syntax-error who "expected a contextual keyword" stx key))
      (cons key (list-ref items (add1 offset)))))

  (define (ground-setting-form value whole-form)
    (cond
      [(identifier? value)
       (case (syntax-e value)
         [(none perfect real) #`(model-ground '#,(syntax-e value))]
         [else
          (raise-syntax-error
           'model
           "expected none, perfect, real, or (real permittivity conductivity)"
           whole-form value)])]
      [else
       (define parts (syntax->list value))
       (unless (and parts
                    (= (length parts) 3)
                    (identifier? (first parts))
                    (eq? (syntax-e (first parts)) 'real))
         (raise-syntax-error
          'model
          "expected none, perfect, real, or (real permittivity conductivity)"
          whole-form value))
       #`(model-ground (real-ground #,(second parts) #,(third parts)))]))

  (define (turn-direction-call direction degrees whole-form)
    (case (syntax-e direction)
      [(left)       #`(turn-z #,degrees)]
      [(right)      #`(turn-z (- #,degrees))]
      [(up)         #`(turn-y (- #,degrees))]
      [(down)       #`(turn-y #,degrees)]
      ;; Aircraft-style naming as viewed by the turtle looking forward:
      ;; roll-left lowers local +Y; roll-right raises it.
      [(roll-left)  #`(turn-x (- #,degrees))]
      [(roll-right) #`(turn-x #,degrees)]
      [else
       (raise-syntax-error
        'turn
        (string-append
         "expected left, right, up, down, roll-left, or roll-right")
        whole-form
        direction)]))

  (define (move-direction-components direction whole-form)
    (case (syntax-e direction)
      [(forward forwards) '(1 0 0)]
      [(back backward backwards) '(-1 0 0)]
      [(left)    '(0 1 0)]
      [(right)   '(0 -1 0)]
      [(up)      '(0 0 1)]
      [(down)    '(0 0 -1)]
      [else
       (raise-syntax-error
        'move
        (string-append
         "expected forward/forwards, back/backward/backwards, left, right, "
         "up, or down")
        whole-form
        direction)]))

  (define (move-axis-expression components temporaries axis)
    (define terms
      (filter
       values
       (for/list ([component (in-list components)]
                  [temporary (in-list temporaries)])
         (define coefficient (list-ref component axis))
         (and (not (zero? coefficient))
              (if (= coefficient 1)
                  temporary
                  #`(- #,temporary))))))
    (cond
      [(null? terms) #'0]
      [(null? (cdr terms)) (car terms)]
      [else #`(+ #,@terms)]))

  ;; Feed locations are contextual DSL keywords. Bare start/center/end and
  ;; the extended (LOCATION NAME AMPLITUDE PHASE) descriptor are converted to
  ;; ordinary runtime values without requiring Scheme quotation syntax.
  (define (feed-descriptor-expression descriptor whole-form)
    (syntax-parse descriptor
      [location:id
       #:when (memq (syntax-e #'location) '(start center end))
       #`'#,(syntax-e #'location)]
      [(location:id name:expr amplitude:expr phase:expr)
       #:when (memq (syntax-e #'location) '(start center end))
       #`(make-feed-spec '#,(syntax-e #'location) name amplitude phase)]
      [(location:id . _)
       #:when (memq (syntax-e #'location) '(start center end))
       (raise-syntax-error
        'feed
        "expected (LOCATION NAME AMPLITUDE PHASE)"
        whole-form
        descriptor)]
      [_ descriptor]))

  (define (reflection-axis direction whole-form)
    (case (syntax-e direction)
      [(forward forwards back backward backwards) 'x]
      [(left right) 'y]
      [(up down) 'z]
      [else
       (raise-syntax-error
        'reflect
        (string-append
         "expected forward/forwards, back/backward/backwards, left, right, "
         "up, or down")
        whole-form
        direction)])))

;; Direction words are contextual syntax keywords. Matching by datum is
;; deliberate: ordinary lexical bindings with these names remain legal.
(define-syntax (turn stx)
  (define pairs
    (syntax-pairs
     'turn stx
     (string-append
      "expected one or more direction/angle pairs, for example "
      "(turn left 90 roll-right 30)")))
  #`(begin
      #,@(for/list ([pair (in-list pairs)])
           (turn-direction-call (car pair) (cdr pair) stx))))

(define-syntax (move stx)
  (define pairs
    (syntax-pairs
     'move stx
     (string-append
      "expected direction/distance pairs and an optional feed/location or "
      "steps/count pair, for example (move forward 10 up 1 steps 5)")))
  (define values
    (for/list ([pair (in-list pairs)])
      (if (eq? (syntax-e (car pair)) 'feed)
          (feed-descriptor-expression (cdr pair) stx)
          (cdr pair))))
  (define temporaries (generate-temporaries values))
  (define movement-pairs
    (for/list ([pair (in-list pairs)]
               [temporary (in-list temporaries)]
               #:unless (memq (syntax-e (car pair)) '(feed steps)))
      (cons (move-direction-components (car pair) stx) temporary)))
  (when (null? movement-pairs)
    (raise-syntax-error 'move "expected at least one movement direction" stx))
  (define feed-temporaries
    (for/list ([pair (in-list pairs)]
               [temporary (in-list temporaries)]
               #:when (eq? (syntax-e (car pair)) 'feed))
      temporary))
  (when (> (length feed-temporaries) 1)
    (raise-syntax-error 'move "feed may be specified only once" stx))
  (define step-temporaries
    (for/list ([pair (in-list pairs)]
               [temporary (in-list temporaries)]
               #:when (eq? (syntax-e (car pair)) 'steps))
      temporary))
  (when (> (length step-temporaries) 1)
    (raise-syntax-error 'move "steps may be specified only once" stx))
  (when (and (pair? feed-temporaries) (pair? step-temporaries))
    (raise-syntax-error
     'move
     "feed and steps may not be combined; mark the desired segment explicitly"
     stx))
  (define components (map car movement-pairs))
  (define distance-temporaries (map cdr movement-pairs))
  (define bindings
    (for/list ([temporary (in-list temporaries)]
               [value (in-list values)])
      #`[#,temporary #,value]))
  (define x-expression
    (move-axis-expression components distance-temporaries 0))
  (define y-expression
    (move-axis-expression components distance-temporaries 1))
  (define z-expression
    (move-axis-expression components distance-temporaries 2))
  #`(let* (#,@bindings)
      #,@(if (null? feed-temporaries)
             '()
             (list #`(mark-feed #,(car feed-temporaries))))
      #,(if (null? step-temporaries)
            #`(move-vector-local
               #,x-expression #,y-expression #,z-expression)
            #`(move-vector-local-steps
               #,x-expression #,y-expression #,z-expression
               #,(car step-temporaries)))))

;; Place stationary geometry endpoints relative to the current turtle frame.
;; The first call establishes a trace anchor; later calls emit edges without
;; moving the turtle itself. Its direction grammar deliberately mirrors move.
(define-syntax (point stx)
  (define pairs
    (syntax-pairs
     'point stx
     (string-append
      "expected direction/distance pairs and an optional feed/location pair, "
      "for example (point right radius up height feed 'center)")))
  (define values
    (for/list ([pair (in-list pairs)])
      (if (eq? (syntax-e (car pair)) 'feed)
          (feed-descriptor-expression (cdr pair) stx)
          (cdr pair))))
  (define temporaries (generate-temporaries values))
  (define direction-pairs
    (for/list ([pair (in-list pairs)]
               [temporary (in-list temporaries)]
               #:unless (eq? (syntax-e (car pair)) 'feed))
      (cons (move-direction-components (car pair) stx) temporary)))
  (when (null? direction-pairs)
    (raise-syntax-error 'point "expected at least one point direction" stx))
  (define feed-temporaries
    (for/list ([pair (in-list pairs)]
               [temporary (in-list temporaries)]
               #:when (eq? (syntax-e (car pair)) 'feed))
      temporary))
  (when (> (length feed-temporaries) 1)
    (raise-syntax-error 'point "feed may be specified only once" stx))
  (define components (map car direction-pairs))
  (define distance-temporaries (map cdr direction-pairs))
  (define bindings
    (for/list ([temporary (in-list temporaries)]
               [value (in-list values)])
      #`[#,temporary #,value]))
  (define x-expression
    (move-axis-expression components distance-temporaries 0))
  (define y-expression
    (move-axis-expression components distance-temporaries 1))
  (define z-expression
    (move-axis-expression components distance-temporaries 2))
  (define feed-expression
    (if (null? feed-temporaries) #'#f (car feed-temporaries)))
  #`(let* (#,@bindings)
      (point-vector-local #,x-expression #,y-expression #,z-expression
                          #,feed-expression)))

(define-syntax (spread stx)
  (syntax-parse stx
    [(_ direction:id distance:expr)
     (define component (move-direction-components #'direction stx))
     #`(spread-local #,@component distance)]
    [(_ direction:id distance:expr (~datum feed) descriptor:expr)
     (define component (move-direction-components #'direction stx))
     (define feed-expression
       (feed-descriptor-expression #'descriptor stx))
     #`(let* ([saved-distance distance]
              [saved-feed #,feed-expression])
         (mark-feed saved-feed)
         (spread-local #,@component saved-distance))]
    [(_ . _)
     (raise-syntax-error
      'spread
      (string-append
       "expected (spread direction distance) or "
       "(spread direction distance feed descriptor)")
      stx)]))

(define-syntax (feed stx)
  (syntax-parse stx
    [(_ descriptor)
     (define expression
       (feed-descriptor-expression #'descriptor stx))
     #`(mark-feed #,expression)]
    [(_ . _)
     (raise-syntax-error
      'feed
      "expected (feed LOCATION) or (feed (LOCATION NAME AMPLITUDE PHASE))"
      stx)]))

;; The direction names select the normal of a reflection plane in the local
;; frame captured on entry. Opposite names intentionally describe the same
;; plane: up and down both reflect across local XY, for example.
(define-syntax (reflect stx)
  (syntax-parse stx
    [(_ direction:id body ...+)
     (define axis (reflection-axis #'direction stx))
     #`(call-with-reflection '#,axis (lambda () body ...))]
    [(_ . _)
     (raise-syntax-error
      'reflect
      "expected (reflect direction body ...+)"
      stx)]))

(define-syntax-rule (radial-repeat count body ...)
  (call-with-radial-repeat count (lambda () body ...)))

(define-syntax (model stx)
  (define pairs
    (if (null? (cdr (syntax->list stx)))
        '()
        (syntax-pairs
         'model stx
         (string-append
          "expected setting/value pairs using title, frequency, max-length, "
          "snaplen, nec2-patch-length, wire-diameter, impedance, ground, or height"))))
  (define seen (make-hasheq))
  (define settings (make-hasheq))
  (for ([pair (in-list pairs)])
    (define key (syntax-e (car pair)))
    (unless (memq key '(title frequency max-length snaplen nec2-patch-length wire-diameter
                              impedance ground height))
      (raise-syntax-error
       'model
       (string-append
        "expected title, frequency, max-length, snaplen, nec2-patch-length, wire-diameter, "
        "impedance, ground, or height")
       stx
       (car pair)))
    (when (hash-ref seen key #f)
      (raise-syntax-error
       'model "setting may be specified only once" stx (car pair)))
    (hash-set! seen key #t)
    (hash-set! settings key (cdr pair)))
  ;; A model form is declarative rather than order-sensitive. Apply frequency
  ;; before wavelength-derived height, segmentation, and snapping expressions
  ;; regardless of the pair order written by the programmer.
  (define forms
    (filter
     values
     (for/list ([key '(title frequency ground height max-length snaplen nec2-patch-length
                            wire-diameter impedance)])
       (define value (hash-ref settings key #f))
       (and value
            (case key
              [(title)         #`(model-title #,value)]
              [(frequency)     #`(model-frequency #,value)]
              [(ground)        (ground-setting-form value stx)]
              [(height)        #`(model-height #,value)]
              [(max-length)    #`(maximum-segment-length #,value)]
              [(snaplen)       #`(snap-length #,value)]
              [(nec2-patch-length)
               #`(maximum-nec2c-patch-length #,value)]
              [(wire-diameter) #`(wire-diameter #,value)]
              [(impedance)     #`(model-impedance #,value)])))))
  #`(begin #,@forms))

(define-syntax-rule (with-wire body ...)
  (call-with-wire (lambda () body ...)))

(define-syntax-rule (with-points body ...)
  (call-with-points (lambda () body ...)))

(define-syntax-rule (from-here body ...)
  (call-from-here (lambda () body ...)))

(define-syntax-rule (with-warp mapper body ...)
  (call-with-warp mapper (lambda () body ...)))

(define-syntax-rule (with-surface height-function body ...)
  (call-with-surface height-function (lambda () body ...)))

(define-syntax-rule (with-pen body ...)
  (with-wire body ...))

(define-syntax-rule (with-scale factor body ...)
  (call-with-scale factor (lambda () body ...)))

(define-syntax-rule (with-push body ...)
  (from-here body ...))
