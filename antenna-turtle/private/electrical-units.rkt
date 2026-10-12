#lang racket/base

(provide ohm ohms kiloohm kiloohms megaohm megaohms
         henry henries millihenry millihenries microhenry microhenries
         nanohenry nanohenries farad farads millifarad millifarads
         microfarad microfarads nanofarad nanofarads picofarad picofarads)

;; Electrical quantities use SI units and are deliberately unaffected by
;; with-scale, which changes spatial geometry only.
(define ohm 1) (define ohms ohm)
(define kiloohm 1e3) (define kiloohms kiloohm)
(define megaohm 1e6) (define megaohms megaohm)
(define henry 1) (define henries henry)
(define millihenry 1e-3) (define millihenries millihenry)
(define microhenry 1e-6) (define microhenries microhenry)
(define nanohenry 1e-9) (define nanohenries nanohenry)
(define farad 1) (define farads farad)
(define millifarad 1e-3) (define millifarads millifarad)
(define microfarad 1e-6) (define microfarads microfarad)
(define nanofarad 1e-9) (define nanofarads nanofarad)
(define picofarad 1e-12) (define picofarads picofarad)
