#lang racket

(require rackunit
         racket/string
         (only-in plot/no-gui plot3d-bitmap)
         "../antenna-turtle/main.rkt"
         (only-in "../antenna-turtle/private/export-nec2c.rkt"
                  write-nec2c-deck)
         (only-in "../antenna-turtle/private/view.rkt"
                  model->plot-renderers))

(define (deck-text)
  (define output (open-output-string))
  (write-nec2c-deck output)
  (get-output-string output))

(define (deck-lines prefix text)
  (filter (lambda (line) (string-prefix? line prefix))
          (string-split text "\n")))

(define (build-straight-loaded-wire topology)
  (reset-model!)
  (model frequency 30 max-length 0.05 wire-diameter 0.002)
  (with-wire
    (move forward 1 feed center)
    (case topology
      [(parallel)
       (lumped-element forward
         name trap
         resistance 18000
         inductance 1.8e-6
         capacitance 56e-12
         topology parallel
         gap 0.02)]
      [(series)
       (lumped-element forward
         name trap
         resistance 18000
         inductance 1.8e-6
         capacitance 56e-12
         topology series
         gap 0.02)])
    (move forward 1)))

(test-case "inline parallel RLC becomes a dedicated loaded NEC segment"
  (build-straight-loaded-wire 'parallel)
  (define text (deck-text))
  (check-equal? (length (deck-lines "GW " text)) 3)
  (check-equal?
   (deck-lines "GW 3 " text)
   '("GW 3 1 0.990000000000 0.000000000000 0.000000000000 1.010000000000 0.000000000000 0.000000000000 0.001000000000"))
  (check-equal?
   (deck-lines "LD " text)
   '("LD 1 3 1 1 18000.000000000000 0.000001800000 0.000000000056")))

(test-case "series topology selects NEC series loading"
  (build-straight-loaded-wire 'series)
  (check-true (string-contains? (deck-text) "LD 0 3 1 1")))

(test-case "a separately declared marker resolves within snap-length"
  (reset-model!)
  (model frequency 30 max-length 0.05 wire-diameter 0.002)
  (snap-length 0.001)
  (with-wire
    (move forward 1 feed center)
    (move forward 1))
  (goto (point3 1.0005 0 0))
  (lumped-element forward resistance 50 gap 0.02)
  (check-equal? (length (deck-lines "LD " (deck-text))) 1))

(test-case "a wire lumped element requires a straight degree-two vertex"
  (reset-model!)
  (model frequency 30 max-length 0.05 wire-diameter 0.002)
  (with-wire
    (move forward 1 feed center)
    (lumped-element forward resistance 50 gap 0.02)
    (turn left 90)
    (move forward 1))
  (check-exn #rx"requires collinear wires"
             (lambda () (deck-text))))

(test-case "reflect duplicates wire loads and show-model renders their markers"
  (reset-model!)
  (model frequency 30 max-length 0.05 wire-diameter 0.002)
  (with-wire (spread up 0.02 feed center))
  (reflect up
    (move up 0.01)
    (with-wire
      (move up 1)
      (lumped-element up
        inductance 1e-6 capacitance 28e-12 topology parallel gap 0.02)
      (move up 1)))
  (check-equal? (length (model-wire-lumped-elements)) 2)
  (check-equal? (length (deck-lines "LD " (deck-text))) 2)
  (define renderers (model->plot-renderers))
  ;; One renderer per wire edge, then feed and lumped-marker renderers.
  (check-equal? (length renderers) (+ (length (model-edges)) 2))
  (check-not-false (plot3d-bitmap renderers #:width 200 #:height 160)))

(test-case "reset-model clears wire lumped declarations"
  (build-straight-loaded-wire 'parallel)
  (check-equal? (length (model-wire-lumped-elements)) 1)
  (clear-wires)
  (check-equal? (model-wire-lumped-elements) '())
  (build-straight-loaded-wire 'parallel)
  (reset-model!)
  (check-equal? (model-wire-lumped-elements) '()))

(define integration-executable
  (or (getenv "NEC2C") (find-executable-path "nec2c")))

(when integration-executable
  (test-case "installed NEC2C accepts an inline parallel RLC model"
    (build-straight-loaded-wire 'parallel)
    (nec2c-executable integration-executable)
    (define result (nec2c-measure-impedance))
    (check-equal? (length (nec2c-impedance-result-samples result)) 1)
    (check-true
     (complex? (nec2c-feedpoint-sample-impedance
                (first (nec2c-impedance-result-samples result)))))))
