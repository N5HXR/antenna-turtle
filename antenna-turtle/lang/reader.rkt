#lang s-exp syntax/module-reader
antenna-turtle/main
#:wrapper1
(lambda (read-one)
  (parameterize ([read-curly-brace-with-tag #t])
    (read-one)))
