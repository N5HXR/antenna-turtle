#lang antenna-turtle

(define design-frequency 146)

(define yagi-1
  '("1-el"
    (drv 493   950)))

(define yagi-2
  '("2-el"
    (ref   0   990)
    (drv 493   950)))

(define yagi-3
  '("3-el"
    (ref   0   990)
    (drv 493   950)
    (dir 647   934)))

(define yagi-4
  '("4-el"
    (ref    0   990)
    (drv  493   950)
    (dir  647   934)
    (dir 1017   925)))

(define yagi-5
  '("5-el"
    (ref    0   990)
    (drv  493   950)
    (dir  647   934)
    (dir 1017   925)
    (dir 1459   917)))

(define yagi-6
  '("6-el"
    (ref    0   990)
    (drv  493   950)
    (dir  647   934)
    (dir 1017   925)
    (dir 1459   917)
    (dir 1973   910)))

(define (build spec)
  (display (format "Building model ~a~n" (car spec)))
  (with-scale millimeter
    (loop for (role pos len) in (cdr spec) do
	  (from-here
	    (move forward pos)
	    (with-wire
	      (when (eq? role 'drv) (feed center))
	      (spread left len))))))

(define cases
  (loop for spec in (list yagi-1 yagi-2 yagi-3 yagi-4 yagi-5 yagi-6) collect
	(begin
	  (reset-model!)
	  ;; reset-model! clears settings as well as geometry, so establish the
	  ;; analysis frequency before generating each independent candidate.
	  (model
	   title (format "Yagi comparison: ~a" (car spec))
	   frequency design-frequency)
	  (build spec)
	  (radiation-case
	   (format "ANT: ~a" (car spec))
	   (nec2c-radiation-grid #:theta-step 1 #:phi-step 1)))))

(show-radiation-comparison cases #:aspect-ratio 16/9 #:palette 'inferno #:scale 'arrl);  #:color-step 1)
