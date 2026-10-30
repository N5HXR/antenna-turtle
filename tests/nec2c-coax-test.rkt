#lang racket

(require rackunit
         racket/string
         (only-in plot/no-gui plot3d-bitmap)
         "../antenna-turtle/main.rkt"
         (only-in "../antenna-turtle/private/export-nec2c.rkt"
                  write-nec2c-deck)
         (only-in "../antenna-turtle/private/view.rkt"
                  model->plot-renderers))

(define (deck-text #:dielectric-resource [resource #f])
  (define output (open-output-string))
  (write-nec2c-deck output #:dielectric-resource resource)
  (get-output-string output))

(define (deck-lines prefix text)
  (filter (lambda (line) (string-prefix? line prefix))
          (string-split text "\n")))

(define (build-coax-fed-dipole)
  (reset-model!)
  (model title "Coax-fed test dipole"
         frequency 14.2
         max-length 0.2
         wire-diameter 0.002
         ground perfect)
  (move up 5)
  (from-here
    (move forward 0.025)
    (with-wire (move forward 1)))
  (from-here
    (move back 0.025)
    (with-wire (move back 1)))
  (define antenna-port
    (wire-port forward name antenna-feed gap 0.05 diameter 0.002))
  (coax name feedline
        output antenna-port
        impedance 50
        velocity-factor 0.66
        diameter 0.0103
        color "dark orange"
        input-gap 0.0254
        input-direction forward
        feed input
    (move down 1)))

(test-case "coax creates a visible shield, two one-segment ports, and a TL card"
  (build-coax-fed-dipole)
  (check-equal? (length (model-wire-ports)) 2)
  (check-equal? (length (model-wire-transmission-lines)) 1)
  (check-equal? (length (model-wire-coaxes)) 1)
  (check-equal?
   (wire-coax-declaration-color (first (model-wire-coaxes)))
   "dark orange")
  (check-equal? (length (model-edges)) 5)
  (define text (deck-text))
  (check-true (string-contains? text "GW 3 1 "))
  (check-true (string-contains? text "GW 5 1 "))
  (check-equal?
   (deck-lines "TL " text)
   '("TL 5 1 3 1 50.000000000000 1.515151515152 0 0 0 0"))
  (check-true (string-contains? text "EX 0 5 1 0 1.000000000000 0.000000000000")))

(test-case "show-model renderers include port polarity markers"
  (build-coax-fed-dipole)
  (define renderers (model->plot-renderers))
  ;; Five conductor edges, one feed marker, and two polarity renderers that
  ;; each contain both port terminals.
  (check-equal? (length renderers) 8)
  (check-not-false (plot3d-bitmap renderers #:width 240 #:height 180)))

(test-case "coax feed is measured at the generated input port"
  (build-coax-fed-dipole)
  (define feeds (filter wire-edge-feed? (model-edges)))
  (check-equal? (length feeds) 1)
  (check-equal? (wire-edge-feed-name (car feeds)) "feedline")
  (check-equal? (wire-edge-feed-location (car feeds)) 'center))

(test-case "network declarations clear with wire geometry"
  (build-coax-fed-dipole)
  (clear-wires)
  (check-equal? (model-wire-ports) '())
  (check-equal? (model-wire-transmission-lines) '())
  (check-equal? (model-wire-coaxes) '()))

(test-case "NEC2C dielectric resources reject TL networks clearly"
  (build-coax-fed-dipole)
  (check-exn #rx"does not support transmission lines with dielectric volumes"
             (lambda () (deck-text #:dielectric-resource "mesh.json"))))

(define integration-executable
  (or (getenv "NEC2C") (find-executable-path "nec2c")))

(when integration-executable
  (test-case "installed NEC2C accepts and solves the coax network"
    (build-coax-fed-dipole)
    (nec2c-executable integration-executable)
    (define result (nec2c-measure-impedance))
    (check-equal? (length (nec2c-impedance-result-samples result)) 1)
    (define impedance
      (nec2c-feedpoint-sample-impedance
       (first (nec2c-impedance-result-samples result))))
    (check-true (complex? impedance))
    (check-true (positive? (real-part impedance)))))
