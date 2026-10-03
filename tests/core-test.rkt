#lang racket

(require rackunit
         racket/file
         racket/runtime-path
         "../antenna-turtle/main.rkt"
         "../antenna-turtle/build.rkt")

(define-runtime-path dipole-model "../examples/dipole.rkt")

;; Direction words are contextual keywords, so an ordinary lexical binding
;; with the same spelling must not affect turn or move.
(define left 'this-binding-must-not-be-evaluated-by-turn-or-move)

(define (only-edge)
  (check-equal? (length (model-edges)) 1)
  (first (model-edges)))

(define (edge-points edge)
  (values (vertex-point (wire-edge-start edge))
          (vertex-point (wire-edge-end edge))))

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

(test-case "exact movement, local turns, and vertex coordinates"
  (reset-model!)
  (pen-down)
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
  (pen-down)
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

(test-case "with-scale restores movement scale without rewinding the turtle"
  (reset-model!)
  (scale 3)
  (pen-down)
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
  (pen-down)
  (forward 1)
  ;; The turn remains, but the temporary factor of 5 does not.
  (check-equal? (vertex-point (wire-edge-end (first (model-edges))))
                (point3 0 2 0)))

(test-case "push and pop restore state but not geometry"
  (reset-model!)
  (pen-down)
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
  (pen-down)
  (forward 0)
  (check-equal? (model-edges) '())
  (feed)
  (check-exn exn:fail? (lambda () (forward 0))))

(test-case "numeric equality merges exact and inexact endpoints"
  (reset-model!)
  (pen-down)
  (forward 1)
  (pen-up)
  (turn-z 180)
  (forward 1.0)
  (turn-z 180)
  (pen-down)
  (forward 2)
  ;; The second drawn edge begins at 0.0, which is numerically equal to 0.
  (check-equal? (length (model-vertices)) 3)
  (check-equal? (vertex-id (wire-edge-start (second (model-edges)))) 1))

(test-case "move-nearest excludes current and previous movement source"
  (reset-model!)
  (pen-down)
  (forward 1)                       ; vertices 0 and 1
  (turn-z 90)
  (forward 1)                       ; now at (1,1), previous source (1,0)
  (move-nearest)                    ; must choose (0,0), not redraw last edge
  (check-equal? (current-position) (point3 0 0 0))
  (check-equal? (length (model-edges)) 3))

(test-case "fed edges receive an odd subdivision count"
  (reset-model!)
  (maximum-segment-length 3/10)
  (pen-down)
  (feed)
  (forward 1)
  (define edge (only-edge))
  (check-true (wire-edge-feed? edge))
  (check-equal? (edge-segment-count edge) 5))

(test-case "arbitrary local axis rotation is supported"
  (reset-model!)
  (turn-axis 180 0 0 10)
  (pen-down)
  (forward 2)
  (check-equal? (current-position) (point3 -2 0 0))
  (check-exn exn:fail? (lambda () (turn-axis 30 0 0 0))))

(test-case "direction macros accept shadowed words and computed expressions"
  (reset-model!)
  (define angle-evaluations 0)
  (define (computed-angle)
    (set! angle-evaluations (add1 angle-evaluations))
    (/ 360 7))
  (turn left (computed-angle))
  (check-equal? angle-evaluations 1)
  (pen-down)
  (forward 1)
  (check-= (point3-x (current-position)) (cos (* 2 pi 1/7)) 1e-12)
  (check-= (point3-y (current-position)) (sin (* 2 pi 1/7)) 1e-12)

  (reset-model!)
  (define distance-evaluations 0)
  (define (computed-distance)
    (set! distance-evaluations (add1 distance-evaluations))
    7/3)
  (pen-down)
  (move left (computed-distance))
  (check-equal? distance-evaluations 1)
  (check-equal? (current-position) (point3 0 7/3 0)))

(test-case "direction convenience forms use the local frame"
  (reset-model!)
  (pen-down)
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

(test-case "move combines direction pairs into one local segment"
  (reset-model!)
  (scale 2)
  (pen-down)
  (feed)
  (move forward 10 up 1 left 2 back 3 down 1/2)
  (define edge (only-edge))
  (check-equal? (current-position) (point3 14 4 1))
  (check-true (wire-edge-feed? edge))
  (check-equal? (vertex-point (wire-edge-start edge)) (point3 0 0 0))
  (check-equal? (vertex-point (wire-edge-end edge)) (point3 14 4 1)))

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

(test-case "with-pen scopes pen state and rejects an already-down pen"
  (reset-model!)
  (define result
    (with-pen
      (define distance 2)
      (move forward distance)
      'body-result))
  (check-equal? result 'body-result)
  (move forward 1) ; initial pen-up state was restored
  (check-equal? (length (model-edges)) 1)
  (check-equal? (current-position) (point3 3 0 0))

  (reset-model!)
  (pen-down)
  (check-exn #rx"pen is already down"
             (lambda () (with-pen (move forward 1))))
  (move forward 1)
  (check-equal? (length (model-edges)) 1))

(test-case "with-pen restores pen state after an exception"
  (reset-model!)
  (check-exn exn:fail?
             (lambda ()
               (with-pen
                 (move forward 1)
                 (error 'model "deliberate test failure"))))
  (move forward 1)
  (check-equal? (length (model-edges)) 1)
  (check-equal? (current-position) (point3 2 0 0)))

(test-case "spread draws one centered segment and preserves a pending feed"
  (reset-model!)
  (pen-down)
  (feed)
  (spread left 10)
  (define edge (only-edge))
  (check-equal? (vertex-point (wire-edge-start edge)) (point3 0 -5 0))
  (check-equal? (vertex-point (wire-edge-end edge)) (point3 0 5 0))
  (check-equal? (current-position) (point3 0 5 0))
  (check-true (wire-edge-feed? edge))

  (reset-model!)
  (pen-down)
  (spread right 10)
  (define reverse-edge (only-edge))
  (check-equal? (vertex-point (wire-edge-start reverse-edge))
                (point3 0 5 0))
  (check-equal? (vertex-point (wire-edge-end reverse-edge))
                (point3 0 -5 0)))

(test-case "with-push restores turtle state and retains geometry"
  (reset-model!)
  (pen-down)
  (with-push
    (forward 2)
    (turn-z 90)
    (forward 3))
  (check-equal? (current-position) (point3 0 0 0))
  (check-equal? (length (model-edges)) 2)
  ;; Restoration also occurs on exceptional exit.
  (with-handlers ([exn:fail? void])
    (with-push
      (forward 4)
      (error 'test "leave pushed scope")))
  (check-equal? (current-position) (point3 0 0 0))
  (check-equal? (length (model-edges)) 3))

(test-case "exporters encode target-specific feed geometry"
  (reset-model!)
  (model-title "Export smoke test")
  (maximum-segment-length 3/10)
  (model-frequency 14.2)
  (pen-down)
  (feed)
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
  (pen-down)
  (feed)
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
  (pen-down)
  (forward 1)
  (turn-z 90)
  (feed)
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
  (pen-down)
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
  (pen-down)
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
  (pen-down)
  (forward 1)
  (feed)
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
  (pen-down)
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
  (pen-down)
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
