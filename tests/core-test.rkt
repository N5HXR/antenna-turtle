#lang racket

(require rackunit
         racket/file
         racket/runtime-path
         "../antenna-turtle/main.rkt"
         "../antenna-turtle/build.rkt")

(define-runtime-path dipole-model "../examples/dipole.rkt")
(define-runtime-path curly-infix-model "curly-infix-model.rkt")

;; Direction words are contextual keywords, so an ordinary lexical binding
;; with the same spelling must not affect turn or move.
(define left 'this-binding-must-not-be-evaluated-by-turn-or-move)

(define (only-edge)
  (check-equal? (length (model-edges)) 1)
  (first (model-edges)))

(define (edge-points edge)
  (values (vertex-point (wire-edge-start edge))
          (vertex-point (wire-edge-end edge))))

(test-case "curly infix expressions retain precedence, exactness, and scope"
  (check-equal? (dynamic-require curly-infix-model 'exact-result) 360/7)
  (check-equal? (dynamic-require curly-infix-model 'precedence-result) 7)
  (check-equal? (dynamic-require curly-infix-model 'lexical-result) 14)
  (check-equal? (dynamic-require curly-infix-model 'nested-result) 9)
  (check-equal? (dynamic-require curly-infix-model 'escaped-result) 6)
  (check-true (dynamic-require curly-infix-model 'comparison-result))
  (define edge (only-edge))
  (define-values (_start finish) (edge-points edge))
  (check-equal? (point3-x finish) 7)
  (check-equal? (point3-y finish) 0)
  (check-equal? (point3-z finish) 1)
  (check-equal? (wire-edge-diameter edge) 1/500))

(test-case "antenna-turtle implicitly provides Common Lisp LOOP"
  (check-equal?
   (loop for value in '(1 2 3 4)
         when (even? value)
         collect (* value value))
   '(4 16)))

(test-case "model-frequency retains the legacy MMANA alias"
  (reset-model!)
  (model-frequency 28.5)
  (check-equal? (mmana-frequency) 28.5)
  (mmana-frequency 29.0)
  (check-equal? (model-frequency) 29.0))

(test-case "model defaults require no declaration and model overrides pairs"
  (reset-model!)
  (check-equal? (model-title) "Turtle Antenna")
  (check-equal? (model-frequency) 141/10)
  (check-equal? (maximum-segment-length) (/ (model-wavelength) 20))
  (check-equal? (snap-length) (/ (model-wavelength) 1000000))
  (define twenty-metre-default (maximum-segment-length))
  (model-frequency 282/10)
  (check-equal? (maximum-segment-length) (/ (model-wavelength) 20))
  (check-not-equal? (maximum-segment-length) twenty-metre-default)
  (model-frequency 141/10)
  (wire-on)
  (forward (model-wavelength))
  (check-equal? (edge-segment-count (only-edge)) 20)
  (check-equal? (wire-edge-diameter (only-edge)) millimeter)
  (define default-nec
    (make-temporary-file "antenna-turtle-defaults~a.nec" #f
                         (current-directory)))
  (export-nec2c default-nec)
  (check-regexp-match #rx"CM Turtle Antenna" (file->string default-nec))
  (check-regexp-match #rx"GW 1 20 " (file->string default-nec))
  (delete-file default-nec)

  (reset-model!)
  (model title "Pair-configured model"
         max-length (/ wavelength 100)
         frequency 7
         snaplen (/ wavelength 2000000)
         wire-diameter (* 2 millimeter))
  (check-equal? (model-title) "Pair-configured model")
  (check-equal? (model-frequency) 7)
  (check-equal? (maximum-segment-length) (/ (model-wavelength) 100))
  (check-equal? (snap-length) (/ (model-wavelength) 2000000))
  (wire-on)
  (forward 1)
  (check-equal? (wire-edge-diameter (only-edge)) (* 2 millimeter))
  (check-exn exn:fail:syntax?
             (lambda () (expand #'(model frequency 7 frequency 14)))))

(test-case "proximity snapping repairs drift and zero disables it"
  (reset-model!)
  (snap-length 1/100)
  (wire-on)
  (forward 1)
  (wire-off)
  (goto (point3 2 0 0))
  (wire-on)
  (goto (point3 1001/1000 0 0))
  (check-equal? (current-position) (point3 1 0 0))
  (check-equal? (length (model-vertices)) 3)
  (check-equal? (vertex-id (wire-edge-end (second (model-edges)))) 2)

  ;; A near start reached while the wire is off is canonicalized when drawing
  ;; resumes, so subsequent geometry shares the existing junction.
  (wire-off)
  (goto (point3 1001/1000 0 0))
  (wire-on)
  (forward 1)
  (check-equal? (vertex-id (wire-edge-start (third (model-edges)))) 2)

  ;; The source of the prospective edge is not an eligible proximity target;
  ;; otherwise a deliberately short segment would disappear.
  (reset-model!)
  (snap-length 1/100)
  (wire-on)
  (forward 1/1000)
  (check-equal? (length (model-edges)) 1)
  (check-equal? (length (model-vertices)) 2)

  (reset-model!)
  (snap-length 0)
  (wire-on)
  (forward 1)
  (wire-off)
  (goto (point3 2 0 0))
  (wire-on)
  (goto (point3 1001/1000 0 0))
  (check-equal? (current-position) (point3 1001/1000 0 0))
  (check-equal? (length (model-vertices)) 4)
  (check-exn exn:fail? (lambda () (snap-length -1))))

(test-case "frequency, wavelength, span, and retuning helpers remain exact"
  (reset-model!)
  (check-equal? wavelength (model-wavelength))
  (check-equal? half-wave (/ wavelength 2))
  (check-equal? quarter-wave (/ wavelength 4))
  (check-equal? (frequency->wavelength 1) 149896229/500000)
  (check-equal? (wavelength->frequency (frequency->wavelength 446)) 446)
  (model-frequency 446)
  ;; The identifier forms resolve dynamically rather than retaining the
  ;; wavelength that was current before model-frequency changed.
  (check-equal? (model-wavelength) (frequency->wavelength 446))
  (check-equal? wavelength (frequency->wavelength 446))
  (check-equal? (span wavelength millimeter)
                (/ 149896229 223000))
  (check-equal? (span (* -2 centimeter) millimeter) -20)
  (check-equal? (frequency-retuning-scale 57/2 29) 57/58)
  (check-exn exn:fail? (lambda () (frequency->wavelength 0)))
  (check-exn exn:fail? (lambda () (wavelength->frequency -1)))
  (check-exn exn:fail? (lambda () (span 1 0)))
  (check-exn exn:fail? (lambda () (frequency-retuning-scale 28.5 0))))

(test-case "exact movement, local turns, and vertex coordinates"
  (reset-model!)
  (wire-on)
  (forward 3/2)
  (turn-z 90)
  (forward 2)
  (check-equal? (length (model-edges)) 2)
  (check-equal? (current-position) (point3 3/2 2 0))
  (check-true (andmap exact?
                      (list (point3-x (current-position))
                            (point3-y (current-position))
                            (point3-z (current-position))))))

(test-case "scale and scale-all have distinct diameter behavior"
  (reset-model!)
  (wire-on)
  (scale 2)
  (forward 1)
  (define first-edge (only-edge))
  (check-equal? (edge-length first-edge) 2)
  (check-equal? (wire-edge-diameter first-edge) millimeter)
  (scale-all 3)
  (forward 1)
  (define second-edge (second (model-edges)))
  (check-equal? (edge-length second-edge) 6)
  (check-equal? (wire-edge-diameter second-edge) (* 3 millimeter)))

(test-case "wire-used measures actual generated conductor length"
  (reset-model!)
  (check-equal? (wire-used) 0)

  ;; Wire-off travel and a lone point anchor do not consume conductor.
  (move forward 9)
  (point right 2)
  (check-equal? (wire-used) 0)
  (wire-off)

  ;; Combined-axis movement is measured by its Euclidean edge length after
  ;; movement scale has been applied, rather than by its component distances.
  (define mark (wire-used))
  (with-scale 2
    (with-wire
      (move forward 3 up 4)))
  (check-equal? (- (wire-used) mark) 10)

  ;; Stationary point geometry and reflected copies count as physical wire.
  (with-points
    (point left 1)
    (point left 1 up 5))
  (check-equal? (wire-used) 15)
  (reflect up
    (with-wire (move up 2)))
  (check-equal? (wire-used) 19)

  ;; Tooling may inspect a retained model after the active model is reset.
  (define completed-model (current-antenna-model))
  (reset-model!)
  (check-equal? (wire-used) 0)
  (check-equal? (wire-used completed-model) 19))

(test-case "with-scale restores movement scale without rewinding the turtle"
  (reset-model!)
  (scale 3)
  (wire-on)
  (with-scale 2
    (forward 1)
    (turn-z 90))
  (forward 1)
  (define edges (model-edges))
  (check-equal? (vertex-point (wire-edge-end (first edges)))
                (point3 6 0 0))
  ;; Orientation from the body survives, while movement scale returns to 3.
  (check-equal? (vertex-point (wire-edge-end (second edges)))
                (point3 6 3 0)))

(test-case "with-scale restores movement scale after an exception"
  (reset-model!)
  (scale 2)
  (with-handlers ([exn:fail? void])
    (with-scale 5
      (turn-z 90)
      (error 'test "leave the scaled scope")))
  (wire-on)
  (forward 1)
  ;; The turn remains, but the temporary factor of 5 does not.
  (check-equal? (vertex-point (wire-edge-end (first (model-edges))))
                (point3 0 2 0)))

(test-case "push and pop restore state but not geometry"
  (reset-model!)
  (wire-on)
  (push)
  (turn-z 90)
  (wire-diameter (* 4 millimeter))
  (forward 1)
  (pop)
  (forward 1)
  (check-equal? (length (model-edges)) 2)
  (check-equal? (current-position) (point3 1 0 0))
  (check-equal? (wire-edge-diameter (first (model-edges))) (* 4 millimeter))
  (check-equal? (wire-edge-diameter (second (model-edges))) millimeter)
  (check-exn exn:fail? pop))

(test-case "zero movement is legal except when a feed is pending"
  (reset-model!)
  (wire-on)
  (forward 0)
  (check-equal? (model-edges) '())
  (feed 'center)
  (check-exn exn:fail? (lambda () (forward 0))))

(test-case "numeric equality merges exact and inexact endpoints"
  (reset-model!)
  (wire-on)
  (forward 1)
  (wire-off)
  (turn-z 180)
  (forward 1.0)
  (turn-z 180)
  (wire-on)
  (forward 2)
  ;; The second drawn edge begins at 0.0, which is numerically equal to 0.
  (check-equal? (length (model-vertices)) 3)
  (check-equal? (vertex-id (wire-edge-start (second (model-edges)))) 1))

(test-case "move-nearest excludes current and previous movement source"
  (reset-model!)
  (wire-on)
  (forward 1)                       ; vertices 0 and 1
  (turn-z 90)
  (forward 1)                       ; now at (1,1), previous source (1,0)
  (move-nearest)                    ; must choose (0,0), not redraw last edge
  (check-equal? (current-position) (point3 0 0 0))
  (check-equal? (length (model-edges)) 3))

(test-case "fed edges receive an odd subdivision count"
  (reset-model!)
  (maximum-segment-length 3/10)
  (wire-on)
  (feed 'center)
  (forward 1)
  (define edge (only-edge))
  (check-true (wire-edge-feed? edge))
  (check-equal? (edge-segment-count edge) 5))

(test-case "arbitrary local axis rotation is supported"
  (reset-model!)
  (turn-axis 180 0 0 10)
  (wire-on)
  (forward 2)
  (check-equal? (current-position) (point3 -2 0 0))
  (check-exn exn:fail? (lambda () (turn-axis 30 0 0 0))))

(test-case "turn chains rotations sequentially and supports readable roll"
  (reset-model!)
  (turn left 90 roll-left 90)
  (wire-on)
  (move forward 1 left 1)
  ;; Yaw maps forward to global +Y. A left roll lowers local +Y to global -Z.
  (check-equal? (current-position) (point3 0 1 -1))

  (reset-model!)
  (turn roll-right 90)
  (wire-on)
  (move left 1)
  (check-equal? (current-position) (point3 0 0 1)))

(test-case "direction macros accept shadowed words and computed expressions"
  (reset-model!)
  (define angle-evaluations 0)
  (define (computed-angle)
    (set! angle-evaluations (add1 angle-evaluations))
    (/ 360 7))
  (turn left (computed-angle))
  (check-equal? angle-evaluations 1)
  (wire-on)
  (forward 1)
  (check-= (point3-x (current-position)) (cos (* 2 pi 1/7)) 1e-12)
  (check-= (point3-y (current-position)) (sin (* 2 pi 1/7)) 1e-12)

  (reset-model!)
  (define distance-evaluations 0)
  (define (computed-distance)
    (set! distance-evaluations (add1 distance-evaluations))
    7/3)
  (wire-on)
  (move left (computed-distance))
  (check-equal? distance-evaluations 1)
  (check-equal? (current-position) (point3 0 7/3 0)))

(test-case "direction convenience forms use the local frame"
  (reset-model!)
  (wire-on)
  (move forward 2)
  (turn up 90)
  (move forward 3)
  (move right 4)
  (move down 5)
  ;; After pitching up, local forward is global +Z, local right is global -Y,
  ;; and local down is global +X.
  (check-equal? (current-position) (point3 7 -4 3))
  (back 3)
  (check-equal? (current-position) (point3 7 -4 0)))

(test-case "longitudinal direction synonyms are equivalent"
  (reset-model!)
  (wire-on)
  (forwards 5)
  (backward 1)
  (backwards 1)
  (move forwards 2 backward 1 backwards 1)
  (check-equal? (current-position) (point3 3 0 0))
  (spread backwards 2)
  (check-equal? (current-position) (point3 2 0 0)))

(test-case "move combines direction pairs into one local segment"
  (reset-model!)
  (scale 2)
  (wire-on)
  (feed 'center)
  (move forward 10 up 1 left 2 back 3 down 1/2)
  (define edge (only-edge))
  (check-equal? (current-position) (point3 14 4 1))
  (check-true (wire-edge-feed? edge))
  (check-equal? (vertex-point (wire-edge-start edge)) (point3 0 0 0))
  (check-equal? (vertex-point (wire-edge-end edge)) (point3 14 4 1)))

(test-case "point traces stationary relative endpoints while the wire is off"
  (reset-model!)
  (define evaluations 0)
  (define (radius)
    (set! evaluations (add1 evaluations))
    2)
  (point right (radius))
  (check-equal? evaluations 1)
  (check-equal? (model-vertices) '()) ; a lone point is only an anchor
  (check-equal? (current-position) (point3 0 0 0))
  (turn left 90)
  (move up 1)
  (point right 2)
  (define edge (only-edge))
  (check-equal? (vertex-point (wire-edge-start edge)) (point3 0 -2 0))
  (check-equal? (vertex-point (wire-edge-end edge)) (point3 2 0 1))
  ;; Point tracing never relocates the turtle itself.
  (check-equal? (current-position) (point3 0 0 1)))

(test-case "point supports chained directions, feeds, and snapping"
  (reset-model!)
  (snap-length 1/100)
  (point forward 1 up 2)
  (point forward 2 up 2 feed 'center)
  (check-equal? (wire-edge-feed-location (only-edge)) 'center)
  ;; The next endpoint is close enough to the first endpoint to close there.
  (point forward 1001/1000 up 2)
  (check-equal? (length (model-vertices)) 2)
  (check-equal? (vertex-id (wire-edge-end (second (model-edges)))) 1)
  (check-equal? (current-position) (point3 0 0 0)))

(test-case "point requires wire-off and either wire state command terminates its trace"
  (reset-model!)
  (point forward 1)
  (wire-on) ; discard the lone point anchor
  (check-exn #rx"wire to be off" (lambda () (point forward 2)))
  (wire-off)
  (point forward 2)
  (point forward 3)
  (define edge (only-edge))
  (check-equal? (vertex-point (wire-edge-start edge)) (point3 2 0 0))
  (check-equal? (vertex-point (wire-edge-end edge)) (point3 3 0 0))
  ;; Ending with an open point anchor is explicitly valid.
  (validate-model!)

  ;; wire-off also snips a trace without requiring an extraneous wire-on.
  (reset-model!)
  (point forward 1)
  (wire-off)
  (point forward 2)
  (point forward 4)
  (define snipped-edge (only-edge))
  (check-equal? (vertex-point (wire-edge-start snipped-edge))
                (point3 2 0 0))
  (check-equal? (vertex-point (wire-edge-end snipped-edge))
                (point3 4 0 0)))

(test-case "with-points scopes a point trace and cleans up after exceptions"
  (reset-model!)
  (define result
    (with-points
      (point left 1)
      (point left 2)
      'body-result))
  (check-equal? result 'body-result)
  (point right 3)
  (point right 4)
  (define edges (model-edges))
  (check-equal? (length edges) 2)
  (check-equal? (vertex-point (wire-edge-start (second edges)))
                (point3 0 -3 0))

  (reset-model!)
  (check-exn exn:fail?
             (lambda ()
               (with-points
                 (point forward 1)
                 (error 'model "deliberate test failure"))))
  (point forward 2)
  (point forward 3)
  (define post-error-edge (only-edge))
  (check-equal? (vertex-point (wire-edge-start post-error-edge))
                (point3 2 0 0))

  (reset-model!)
  (wire-on)
  (check-exn #rx"wire must be off"
             (lambda () (with-points (void))))
  (wire-off)
  (point forward 1)
  (check-exn #rx"already active"
             (lambda () (with-points (void)))))

(test-case "point rejects a feed before its first segment"
  (reset-model!)
  (check-exn #rx"first point" (lambda () (point forward 1 feed 'center)))
  (check-equal? (model-edges) '())
  (validate-model!)
  (check-exn #rx"start.*center.*end"
             (lambda () (point forward 1 feed #t))))

(test-case "push and pop restore the point trace anchor"
  (reset-model!)
  (point forward 1)
  (push)
  (turn left 90)
  (point forward 2)
  (pop)
  (point forward 3)
  (define edges (model-edges))
  (check-equal? (length edges) 2)
  (check-equal? (vertex-point (wire-edge-start (first edges)))
                (point3 1 0 0))
  (check-equal? (vertex-point (wire-edge-end (first edges)))
                (point3 0 2 0))
  (check-equal? (vertex-point (wire-edge-start (second edges)))
                (point3 1 0 0))
  (check-equal? (vertex-point (wire-edge-end (second edges)))
                (point3 3 0 0)))

(test-case "move and spread accept explicit feed locations"
  (reset-model!)
  (wire-on)
  (move forward 2 feed 'start)
  (check-equal? (wire-edge-feed-location (only-edge)) 'start)

  (reset-model!)
  (wire-on)
  (spread left 10 feed 'end)
  (check-equal? (wire-edge-feed-location (only-edge)) 'end)
  (check-exn #rx"start.*center.*end"
             (lambda ()
               (reset-model!)
               (wire-on)
               (move forward 1 feed #t))))

(test-case "chained move evaluates distances once in source order"
  (reset-model!)
  (define evaluations '())
  (define (distance label value)
    (set! evaluations (append evaluations (list label)))
    value)
  (turn left 90)
  (move forward (distance 'forward 10)
        up      (distance 'up 1)
        forward (distance 'forward-again 2))
  (check-equal? evaluations '(forward up forward-again))
  ;; Local +X has rotated to global +Y; local +Z remains global +Z.
  (check-equal? (current-position) (point3 0 12 1)))

(test-case "with-wire scopes pen state and rejects an already-down pen"
  (reset-model!)
  (define result
    (with-wire
      (define distance 2)
      (move forward distance)
      'body-result))
  (check-equal? result 'body-result)
  (move forward 1) ; initial wire-off state was restored
  (check-equal? (length (model-edges)) 1)
  (check-equal? (current-position) (point3 3 0 0))

  (reset-model!)
  (wire-on)
  (check-exn #rx"wire is already on"
             (lambda () (with-wire (move forward 1))))
  (move forward 1)
  (check-equal? (length (model-edges)) 1))

(test-case "with-wire restores pen state after an exception"
  (reset-model!)
  (check-exn exn:fail?
             (lambda ()
               (with-wire
                 (move forward 1)
                 (error 'model "deliberate test failure"))))
  (move forward 1)
  (check-equal? (length (model-edges)) 1)
  (check-equal? (current-position) (point3 2 0 0)))

(test-case "spread draws one centered segment and preserves a pending feed"
  (reset-model!)
  (wire-on)
  (feed 'center)
  (spread left 10)
  (define edge (only-edge))
  (check-equal? (vertex-point (wire-edge-start edge)) (point3 0 -5 0))
  (check-equal? (vertex-point (wire-edge-end edge)) (point3 0 5 0))
  (check-equal? (current-position) (point3 0 5 0))
  (check-true (wire-edge-feed? edge))

  (reset-model!)
  (wire-on)
  (spread right 10)
  (define reverse-edge (only-edge))
  (check-equal? (vertex-point (wire-edge-start reverse-edge))
                (point3 0 5 0))
  (check-equal? (vertex-point (wire-edge-end reverse-edge))
                (point3 0 -5 0)))

(test-case "from-here restores turtle state and retains geometry"
  (reset-model!)
  (wire-on)
  (from-here
    (forward 2)
    (turn-z 90)
    (forward 3))
  (check-equal? (current-position) (point3 0 0 0))
  (check-equal? (length (model-edges)) 2)
  ;; Restoration also occurs on exceptional exit.
  (with-handlers ([exn:fail? void])
    (from-here
      (forward 4)
      (error 'test "leave pushed scope")))
  (check-equal? (current-position) (point3 0 0 0))
  (check-equal? (length (model-edges)) 3))

(test-case "reflect copies scoped geometry in the captured local frame"
  (reset-model!)
  (wire-diameter (* 3 millimeter))
  (define result
    (reflect up
      (with-wire
        (move up 2 feed 'start)
        (move left 1))
      'body-result))
  (check-equal? result 'body-result)
  (check-equal? (current-position) (point3 0 1 2))
  (check-equal? (length (model-edges)) 4)
  (check-equal? (length (filter wire-edge-feed? (model-edges))) 1)
  (check-equal? (wire-edge-feed-location (first (model-edges))) 'start)
  (check-false (wire-edge-feed-location (third (model-edges))))
  (check-equal? (wire-edge-diameter (third (model-edges)))
                (* 3 millimeter))
  (define reflected-first (third (model-edges)))
  (define reflected-second (fourth (model-edges)))
  (check-equal? (vertex-point (wire-edge-start reflected-first))
                (point3 0 0 0))
  (check-equal? (vertex-point (wire-edge-end reflected-first))
                (point3 0 0 -2))
  (check-equal? (vertex-point (wire-edge-end reflected-second))
                (point3 0 1 -2))

  ;; Geometry wholly inside the reflection plane is not duplicated.
  (reset-model!)
  (reflect down
    (with-wire (move forward 1)))
  (check-equal? (length (model-edges)) 1)

  ;; "up" is relative to the orientation captured on entry, not global Z.
  (reset-model!)
  (turn up 90)
  (reflect up
    (with-wire (move up 2)))
  (check-equal? (length (model-edges)) 2)
  (define endpoints
    (map (lambda (edge) (vertex-point (wire-edge-end edge)))
         (model-edges)))
  (check-equal? endpoints (list (point3 -2 0 0) (point3 2 0 0)))

  (check-exn exn:fail:syntax?
             (lambda () (expand #'(reflect roll-left (void))))))

(test-case "here and goto use exact global coordinates"
  (reset-model!)
  (move forward 2 up 3)
  (define recorded (here))
  (check-equal? recorded (point3 2 0 3))
  (turn left 90)
  (scale 5)
  (move forward 1)
  (wire-on)
  (goto recorded)
  (define edge (only-edge))
  (check-equal? (current-position) recorded)
  (check-equal? (vertex-point (wire-edge-end edge)) recorded)
  (check-exn exn:fail:contract? (lambda () (goto '(2 0 3)))))

(test-case "NEC2C and MMANA encode all feed locations and MATLAB rejects ends"
  (define (export-location location)
    (reset-model!)
    (maximum-segment-length 3/10)
    (wire-on)
    (move forward 1 feed location)
    (define temp-dir
      (make-temporary-file "antenna-turtle-feed-location~a" 'directory
                           (current-directory)))
    (define nec-path (build-path temp-dir "model.nec"))
    (define maa-path (build-path temp-dir "model.maa"))
    (define matlab-path (build-path temp-dir "model.m"))
    (define loft-path (build-path temp-dir "model-loft.m"))
    (export-nec2c nec-path)
    (export-mmana maa-path)
    (values temp-dir nec-path maa-path matlab-path loft-path))
  (for ([location '(start center end)]
        [segment '(1 3 4)]
        [suffix '("b" "c" "e")])
    (define-values (temp-dir nec-path maa-path matlab-path loft-path)
      (export-location location))
    (check-regexp-match
     (regexp (format "EX 0 1 ~a 0" segment))
     (file->string nec-path))
    (check-regexp-match
     (regexp (format "w1~a," suffix))
     (file->string maa-path))
    (if (eq? location 'center)
        (begin
          (check-not-exn (lambda () (export-matlab matlab-path)))
          (check-not-exn (lambda () (export-matlab-loft loft-path))))
        (begin
          (check-exn #rx"supports only center feeds"
                     (lambda () (export-matlab matlab-path)))
          (check-exn #rx"supports only center feeds"
                     (lambda () (export-matlab-loft loft-path)))))
    (delete-directory/files temp-dir)))

(test-case "exporters encode target-specific feed geometry"
  (reset-model!)
  (model-title "Export smoke test")
  (maximum-segment-length 3/10)
  (model-frequency 14.2)
  (wire-on)
  (feed 'center)
  (forward 1)
  (define temp-dir
    (make-temporary-file "antenna-turtle-test~a" 'directory
                         (current-directory)))
  (define nec-path (build-path temp-dir "model.nec"))
  (define maa-path (build-path temp-dir "model.maa"))
  (define matlab-path (build-path temp-dir "model.m"))
  (export-nec2c nec-path)
  (export-mmana maa-path)
  (export-matlab matlab-path)
  (define nec (file->string nec-path))
  (define maa (file->string maa-path))
  (define matlab (file->string matlab-path))
  (check-regexp-match #rx"GW 1 5 " nec)
  (check-regexp-match #rx"EX 0 1 3 0 1[.]0 0[.]0" nec)
  (check-regexp-match #rx"w1c,.*0[.]0,.*1[.]0" maa)
  (check-regexp-match #rx"14[.]200000000000" maa)
  (check-regexp-match #rx"shape[.]Custom3D" matlab)
  (check-regexp-match #rx"createFeed" matlab)
  (check-regexp-match #rx"operatingFrequency = 14200000[.]000000000000" matlab)
  (check-regexp-match #rx"pattern[(]antennaObject, operatingFrequency" matlab)
  ;; A fed rectangle is split into four triangles.
  (define triangle-block
    (second (regexp-match #px"(?s:triangles = \\[ [.][.][.](.*?)\\];)"
                          matlab)))
  (check-equal? (length (regexp-match* #rx"; [.][.][.]" triangle-block)) 4)
  (delete-directory/files temp-dir))

(test-case "MMANA export preserves saved calculation settings"
  (reset-model!)
  (model-title "First generated model")
  (model-frequency 14.2)
  (maximum-segment-length 1/10)
  (wire-on)
  (feed 'center)
  (forward 1)
  (define maa-path
    (make-temporary-file "antenna-turtle-mmana-update~a.maa" #f
                         (current-directory)))
  ;; make-temporary-file creates the path; export's smart-update behavior must
  ;; see a nonexistent destination for this initial generation.
  (delete-file maa-path)
  (export-mmana maa-path)
  (define configured
    (string-replace
     (string-replace
      (file->string maa-path)
      "400,\t80,\t2.0,\t1"
      "777,\t33,\t1.5,\t4")
     "0,\t0.0,\t1,\t50.0,\t120,\t60,\t0"
     "1,\t2.5,\t3,\t75.0,\t90,\t45,\t9"))
  ;; Simulate user changes that Turtle owns and must replace: frequency,
  ;; source drive, and a manually inserted load.
  (define user-edited
    (string-replace
     (string-replace
      (string-replace configured "14.200000000000" "99.0")
      "w1c,\t0.0,\t1.0"
      "w1c,\t45.0,\t0.25")
     "*** Loads ***\n0,\t0"
     "*** Loads ***\n1,\t0\nw1c,\t0,\t50.0"))
  ;; MMANA commonly rewrites files with CRLF line endings.
  (call-with-output-file maa-path
    #:exists 'truncate/replace
    (lambda (out)
      (write-bytes
       (regexp-replace* #rx#"\n" (string->bytes/utf-8 user-edited) #"\r\n")
       out)))

  (reset-model!)
  (model-title "Regenerated model")
  (model-frequency 28.5)
  (maximum-segment-length 1/10)
  (wire-on)
  (forward 1)
  (turn-z 90)
  (feed 'center)
  (forward 1)
  (export-mmana maa-path)
  (define updated (file->bytes maa-path))
  (check-true (regexp-match? #px#"(?m:^Regenerated model\r$)" updated))
  (check-true (regexp-match? #px#"(?m:^28[.]500000000000\r$)" updated))
  (check-true (regexp-match? #px#"(?m:^2\r$)" updated))
  (check-true (regexp-match? #px#"(?m:^w2c,\t0[.]0,\t1[.]0\r$)" updated))
  (check-true (regexp-match? #rx#"[*][*][*] Loads [*][*][*]\r\n0,\t0\r\n" updated))
  (check-false (regexp-match? #rx#"45[.]0,\t0[.]25" updated))
  (check-false (regexp-match? #rx#"w1c,\t0,\t50[.]0" updated))
  (check-true (regexp-match? #px#"(?m:^777,\t33,\t1[.]5,\t4\r$)" updated))
  (check-true (regexp-match? #px#"(?m:^1,\t2[.]5,\t3,\t75[.]0,\t90,\t45,\t9\r?$)" updated))
  (delete-file maa-path))

(test-case "MMANA export refuses to overwrite an unrecognized existing file"
  (reset-model!)
  (model-frequency 7.1)
  (maximum-segment-length 1/10)
  (wire-on)
  (forward 1)
  (define maa-path
    (make-temporary-file "antenna-turtle-mmana-invalid~a.maa" #f
                         (current-directory)))
  (call-with-output-file maa-path
    #:exists 'truncate/replace
    (lambda (out) (display "not an MMANA model\n" out)))
  (check-exn #rx"not recognizable"
             (lambda () (export-mmana maa-path)))
  (check-equal? (file->string maa-path) "not an MMANA model\n")
  (delete-file maa-path))

(test-case "MATLAB strips share a conforming edge at a bend"
  (reset-model!)
  (wire-on)
  (forward 1)
  (turn-z 90)
  (forward 1)
  (define matlab-path
    (make-temporary-file "antenna-turtle-matlab~a.m" #f
                         (current-directory)))
  (export-matlab matlab-path)
  (define matlab (file->string matlab-path))
  (define point-block
    (second (regexp-match #px"(?s:points = \\[ [.][.][.](.*?)\\];)"
                          matlab)))
  (define triangle-block
    (second (regexp-match #px"(?s:triangles = \\[ [.][.][.](.*?)\\];)"
                          matlab)))
  ;; Three path vertices become three shared transverse pairs, not two
  ;; independent four-point rectangles.
  (check-equal? (length (regexp-match* #rx"; [.][.][.]" point-block)) 6)
  (check-equal? (length (regexp-match* #rx"; [.][.][.]" triangle-block)) 4)
  ;; Both strip quads reuse vertex IDs 3 and 4 at the bend.
  (check-regexp-match
   #px"(?s:1 2 4; [.][.][.].*1 4 3; [.][.][.].*3 4 6; [.][.][.].*3 6 5;)"
   triangle-block)
  (delete-file matlab-path))

(test-case "experimental loft MATLAB export emits conformal bevel joints"
  (reset-model!)
  (model-title "Loft export smoke test")
  (model-frequency 7.1)
  (wire-diameter (* 2 millimeter))
  (wire-on)
  (forward 1)
  (feed 'center)
  (turn-z 90)
  (forward 1)
  (define matlab-path
    (make-temporary-file "antenna-turtle-loft~a.m" #f
                         (current-directory)))
  (export-matlab-loft matlab-path)
  (define matlab (file->string matlab-path))
  (check-regexp-match #rx"makeLoftedSquarePath" matlab)
  (check-regexp-match #rx"bestCyclicMapping" matlab)
  ;; A bend may cyclically map its outgoing ring for the joint faces, but the
  ;; next straight tube must retain canonical ring order or it will twist.
  (check-regexp-match
   #rx"mappedOutgoingRing=bestCyclicMapping[(]points,incomingRing,outgoingRing[)]"
   matlab)
  (check-regexp-match
   #rx"startRings[{]following[}]=outgoingRing;[\n ]+triangles=appendTubeFaces[(]triangles,incomingRing,mappedOutgoingRing[)]"
   matlab)
  (check-regexp-match #rx"appendTubeFaces" matlab)
  (check-regexp-match #rx"Loft mesh:" matlab)
  (check-regexp-match #rx"edgeCounts ~= 2" matlab)
  (check-regexp-match #rx"createFeed[(]antennaObject,feedLocation,4[)]" matlab)
  (check-false (regexp-match? #rx"RetainShape" matlab))
  (check-false (regexp-match? #rx"shape[.]Box" matlab))
  (check-regexp-match #rx"operatingFrequency = 7100000[.]000000000000" matlab)
  (check-regexp-match #rx"minimumWireDiameter = 0[.]002000000000" matlab)
  (check-regexp-match
   #rx"analysisMeshMaxEdgeLength = min[(]299792458/[(]10[*]operatingFrequency[)], [.][.][.]"
   matlab)
  (check-regexp-match
   #rx"mesh[(]antennaObject,MaxEdgeLength=analysisMeshMaxEdgeLength[)]"
   matlab)
  (check-false (regexp-match? #rx"MinEdgeLength" matlab))
  (delete-file matlab-path))

(test-case "experimental loft MATLAB export enforces junction constraints"
  (reset-model!)
  (wire-diameter (* 2 millimeter))
  (wire-on)
  (forward 1)
  (wire-diameter (* 3 millimeter))
  (turn-z 90)
  (forward 1)
  (define diameter-path
    (make-temporary-file "antenna-turtle-loft-diameter~a.m" #f
                         (current-directory)))
  (check-exn #rx"equal wire diameters"
             (lambda () (export-matlab-loft diameter-path)))
  (delete-file diameter-path)

  (reset-model!)
  (wire-on)
  (push)
  (forward 1)
  (pop)
  (turn-z 120)
  (push)
  (forward 1)
  (pop)
  (turn-z 120)
  (forward 1)
  (define branch-path
    (make-temporary-file "antenna-turtle-loft-branch~a.m" #f
                         (current-directory)))
  (check-exn #rx"does not yet support branch vertex"
             (lambda () (export-matlab-loft branch-path)))
  (delete-file branch-path))

(test-case "build-model derives output names and supports every format"
  (define output-directory
    (make-temporary-file "antenna-turtle-build~a" 'directory
                         (current-directory)))
  (define outputs
    (build-model dipole-model
                 #:output-directory output-directory
                 #:formats supported-build-formats))
  (check-equal?
   (map (lambda (path) (path->string (file-name-from-path path))) outputs)
   '("dipole.nec" "dipole.maa" "dipole.m" "dipole-ribbon.m"))
  (for ([output (in-list outputs)])
    (check-true (file-exists? output))
    (check-true (> (file-size output) 0)))
  (delete-directory/files output-directory))
