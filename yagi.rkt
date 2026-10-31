#lang antenna-turtle

(model-title "Cross Polarized Yagi")
(model-frequency 438)
(maximum-segment-length (* 20 millimeter))
(wire-diameter (* 3 millimeter))

;; empirically determined scaling factor for the sweet spot
(define tune {434 / 438})

;; we'll move the vertical yagi forward this far
(define shift (* (/ (model-wavelength) 4.1) 1000))

(define (yagi s)
  (loop for (role len pos) in s do
	(with-push
	  (move forward pos)
	  (with-pen
	    (when (eq? role 'drv) (feed))
	    (spread left len)))))

(define (crossed-yagi s)
  (with-scale {tune * millimeter}
    (with-push (yagi s))
    (with-push
      (turn-x 90)
      (move forward shift)
      (yagi s))))

(turn up 45)
(crossed-yagi
 '([ref  330    0]
   [drv  352  164]
   [dir  311  216]
   [dir  308  339]
   [dir  306  486]
   [dir  303  658]))

(export-mmana "mmana/yagi.maa")
    
