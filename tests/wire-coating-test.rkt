#lang racket

(require rackunit
         racket/string
         "../antenna-turtle/main.rkt"
         (only-in "../antenna-turtle/private/export-nec2c.rkt"
                  write-nec2c-deck))

(define petg
  (dielectric name petg
              er 16/5
              loss (narrow 3/200 435)))

(define conductive-jacket
  (dielectric name conductive-jacket
              er 5/2
              conductivity 1/1000000))

;; The low-level material representation can carry both mechanisms, matching
;; LD 7's independent TAN_DELTA and SIGMA_DC fields.
(define lossy-conductive-jacket
  (em-material 'lossy-conductive-jacket 'dielectric
               5/2 1 1/1000000 0 #f
               (make-narrow-loss 1/100 435)))

(define (draw-wire length)
  (wire-on)
  (forward length)
  (wire-off))

(define (deck-string)
  (call-with-output-string write-nec2c-deck))

(test-case "wire coating is captured immutably per edge"
  (reset-model!)
  (wire-diameter (* 2 millimeters))
  (wire-coating material petg diameter (* 12 millimeters))
  (draw-wire 1)
  (wire-coating-off)
  (turn right 90)
  (draw-wire 1)

  (define coated (first (model-edges)))
  (define bare (second (model-edges)))
  (check-equal? (wire-coating-spec-material (wire-edge-coating coated)) petg)
  (check-equal? (wire-coating-spec-outside-diameter
                 (wire-edge-coating coated))
                (* 12 millimeters))
  (check-false (wire-edge-coating bare))
  (check-false (current-wire-coating))
  (check-true (and (wire-edge-coating coated) #t)))

(test-case "scoped coating restores the previous global setting"
  (reset-model!)
  (wire-coating material conductive-jacket diameter (* 10 millimeters))
  (with-wire-coating material petg diameter (* 12 millimeters)
    (draw-wire 1))
  (draw-wire 1)
  (check-equal?
   (wire-coating-spec-material (wire-edge-coating (first (model-edges))))
   petg)
  (check-equal?
   (wire-coating-spec-material (wire-edge-coating (second (model-edges))))
   conductive-jacket)
  (check-equal? (wire-coating-spec-material (current-wire-coating))
                conductive-jacket)
  (check-exn
   exn:fail?
   (lambda ()
     (with-wire-coating material petg diameter (* 14 millimeters)
       (error 'test "leave scope abnormally"))))
  (check-equal? (wire-coating-spec-material (current-wire-coating))
                conductive-jacket))

(test-case "reset clears coating while clear-wires preserves it"
  (reset-model!)
  (wire-coating material petg diameter (* 12 millimeters))
  (clear-wires)
  (check-equal? (wire-coating-spec-material (current-wire-coating)) petg)
  (reset-model!)
  (check-false (current-wire-coating)))

(test-case "scale-all scales coating diameter and ordinary scale does not"
  (reset-model!)
  (wire-coating material petg diameter (* 12 millimeters))
  (scale 2)
  (draw-wire 1)
  (scale-all 2)
  (draw-wire 1)
  (check-equal?
   (wire-coating-spec-outside-diameter
    (wire-edge-coating (first (model-edges))))
   (* 12 millimeters))
  (check-equal?
   (wire-coating-spec-outside-diameter
    (wire-edge-coating (second (model-edges))))
   (* 24 millimeters)))

(test-case "coating outside diameter cannot be smaller than the metal"
  (reset-model!)
  (wire-diameter (* 4 millimeters))
  (wire-coating material petg diameter (* 3 millimeters))
  (check-exn #rx"outside diameter must be at least"
             (lambda () (draw-wire 1))))

(test-case "coating material validation rejects unsupported material models"
  (reset-model!)
  (define metal
    (conductor name test-metal conductivity 1000000))
  (define broadband
    (dielectric name broadband-jacket
                er 3
                loss (broad 1/100 400 500)))
  (check-exn exn:fail:contract?
             (lambda ()
               (wire-coating material metal diameter (* 12 millimeters))))
  (check-exn #rx"broadband and relaxation coatings are not yet supported"
             (lambda ()
               (wire-coating material broadband
                             diameter (* 12 millimeters)))))

(test-case "reflection preserves captured coating"
  (reset-model!)
  (wire-coating material petg diameter (* 12 millimeters))
  (reflect left
    (with-wire
      (move forward 1 left 1)))
  (check-equal? (length (model-edges)) 2)
  (for ([edge (in-list (model-edges))])
    (check-equal? (wire-edge-coating edge)
                  (wire-edge-coating (first (model-edges))))))

(test-case "NEC2C emits one complete-tag LD 7 card per coated edge"
  (reset-model!)
  (model-frequency 435)
  (maximum-segment-length 1/20)
  (wire-coating material petg diameter (* 12 millimeters))
  (feed center)
  (draw-wire 1)
  (wire-coating material lossy-conductive-jacket
                diameter (* 8 millimeters))
  (draw-wire 1)
  (wire-coating-off)
  (draw-wire 1)
  (define deck (deck-string))
  (check-regexp-match
   #rx"LD 7 1 0 0 3\\.200000000000 0\\.006000000000 0\\.015000000000 0\\.000000000000"
   deck)
  (check-regexp-match
   #rx"LD 7 2 0 0 2\\.500000000000 0\\.004000000000 0\\.010000000000 0\\.000001000000"
   deck)
  (check-equal? (length (regexp-match* #rx"(?m:^LD 7 )" deck)) 2))

(test-case "bare NEC2C decks remain free of coated-wire cards"
  (reset-model!)
  (draw-wire 1)
  (check-false (string-contains? (deck-string) "LD 7")))

(test-case "unsupported exporters reject coated wires explicitly"
  (reset-model!)
  (wire-coating material petg diameter (* 12 millimeters))
  (draw-wire 1)
  (define path
    (make-temporary-file "antenna-turtle-coated~a" #f (current-directory)))
  (dynamic-wind
    void
    (lambda ()
      (for ([exporter (in-list (list export-mmana
                                     export-matlab
                                     export-matlab-loft))])
        (check-exn #rx"supported only by the NEC2C backend"
                   (lambda () (exporter path)))))
    (lambda () (when (file-exists? path) (delete-file path)))))

(test-case "experimental mixed-junction setting is explicit and persistent"
  (set-coating-experimental #f)
  (check-false (coating-experimental?))
  (set-coating-experimental #t)
  (reset-model!)
  (check-true (coating-experimental?))
  (check-exn exn:fail:contract?
             (lambda () (set-coating-experimental 'yes)))
  (set-coating-experimental #f))
