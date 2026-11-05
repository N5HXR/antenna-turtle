#lang racket

(require rackunit
         "../antenna-turtle/main.rkt")

(test-case "segmentation report measures solver segments and wire components"
  (reset-model!)
  ;; Choose a one-metre wavelength so wavelength totals are easy to verify.
  (model-frequency 299.792458)
  (maximum-segment-length 1/4)
  (wire-on)
  (goto (point3 1 0 0))
  (goto (point3 1 1/2 0))
  (wire-off)
  (goto (point3 2 1/2 0))
  (wire-on)
  (goto (point3 2 7/10 0))

  (define report (nec2c-segmentation-report))
  (check-equal? (segmentation-report-wire-edge-count report) 3)
  (check-equal? (segmentation-report-segment-count report) 7)
  (check-equal? (segmentation-report-contiguous-path-count report) 2)
  (check-= (segmentation-report-total-length-m report) 1.7 1e-12)
  (check-= (segmentation-report-total-length-wavelengths report) 1.7 1e-12)
  (check-= (segmentation-report-minimum-segment-length-m report) 0.2 1e-12)
  (check-= (segmentation-report-average-segment-length-m report)
           (/ 1.7 7) 1e-12)
  (check-= (segmentation-report-maximum-segment-length-m report) 0.25 1e-12)
  (check-equal? (segmentation-report-bounds-minimum report) (point3 0 0 0))
  (check-equal? (segmentation-report-bounds-maximum report) (point3 2 7/10 0))
  (check-equal? (segmentation-report-x-span-m report) 2)
  (check-equal? (segmentation-report-y-span-m report) 7/10)
  (check-equal? (segmentation-report-z-span-m report) 0)
  (check-equal? (segmentation-report-bounding-volume-m3 report) 0)

  (define rendered (open-output-string))
  (check-eq? (show-segmentation-report report rendered) report)
  (define text (get-output-string rendered))
  (check-regexp-match #rx"NEC wire segments:[ ]+7" text)
  (check-regexp-match #rx"Contiguous wire paths:[ ]+2" text)
  (check-regexp-match #rx"Total wire length:[ ]+1[.]700000 m" text))

(test-case "NEC wire ports remain one segment regardless of target length"
  (reset-model!)
  (maximum-segment-length 1/10)
  (wire-port test-port forward gap 1)
  (define report (nec2c-segmentation-report))
  (check-equal? (segmentation-report-wire-edge-count report) 1)
  (check-equal? (segmentation-report-segment-count report) 1)
  (check-equal? (segmentation-report-minimum-segment-length-m report) 1)
  (check-equal? (segmentation-report-maximum-segment-length-m report) 1))

(test-case "empty models have zero-valued aggregate statistics"
  (reset-model!)
  (define report (nec2c-segmentation-report))
  (check-equal? (segmentation-report-segment-count report) 0)
  (check-equal? (segmentation-report-total-length-m report) 0)
  (check-false (segmentation-report-minimum-segment-length-m report))
  (check-false (segmentation-report-maximum-segment-length-m report))
  (check-false (segmentation-report-bounds-minimum report))
  (check-equal? (segmentation-report-bounding-volume-m3 report) 0))
