;;; antenna-turtle-emacs.el --- Emacs support for Antenna Turtle -*- lexical-binding: t; -*-

;; Load this file from init.el after adjusting the path:
;;
;;   (load "C:/path/to/antenna-turtle/editors/antenna-turtle-emacs.el")
;;
;; It augments scheme-mode only in buffers whose first form is
;; `#lang antenna-turtle`.

(require 'scheme)

(defface antenna-turtle-api-face
  '((t :inherit font-lock-builtin-face :weight bold))
  "Face for Antenna Turtle procedures."
  :group 'scheme)

(defface antenna-turtle-macro-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for Antenna Turtle and LOOP macros."
  :group 'scheme)

(defface antenna-turtle-loop-clause-face
  '((t :inherit font-lock-keyword-face))
  "Face for Common Lisp LOOP clause words."
  :group 'scheme)

(defface antenna-turtle-direction-face
  '((t :inherit font-lock-constant-face))
  "Face for contextual movement and turn directions."
  :group 'scheme)

(defface antenna-turtle-infix-operator-face
  '((t :inherit font-lock-builtin-face :weight bold))
  "Face for operators used in Antenna Turtle curly infix expressions."
  :group 'scheme)

(defface antenna-turtle-infix-delimiter-face
  '((t :inherit shadow))
  "Muted face for curly infix delimiters."
  :group 'scheme)

(defconst antenna-turtle--procedures
  '("model-title" "maximum-segment-length" "model-frequency"
    "mmana-frequency" "wire-diameter"
    "frequency->wavelength" "wavelength->frequency" "model-wavelength"
    "span" "frequency-retuning-scale"
    "wire-off" "wire-on" "here" "goto"
    "pen-up" "pen-down" "forward" "back" "move-nearest"
    "turn-x" "turn-y" "turn-z" "turn-axis"
    "scale" "scale-all" "push" "pop" "feed"
    "reset-model!" "validate-model!" "current-position"
    "current-wire-diameter" "current-antenna-model"
    "model-vertices" "model-edges" "edge-length"
    "edge-segment-count"
    "export-nec2c" "export-mmana" "export-matlab"
    "export-matlab-loft" "build-model"))

(defconst antenna-turtle--macros
  '("model" "move" "spread" "turn"
    "with-wire" "from-here" "with-scale" "with-pen" "with-push"
    "loop" "return" "return-from"))

(defconst antenna-turtle--loop-clauses
  '("for" "as" "from" "downfrom" "to" "upto" "downto"
    "below" "above" "by" "in" "on" "across" "repeat"
    "while" "until" "always" "never" "thereis"
    "collect" "collecting" "append" "appending" "nconc" "nconcing"
    "count" "counting" "sum" "summing" "maximize" "maximizing"
    "minimize" "minimizing" "do" "doing" "initially" "finally"
    "if" "when" "unless" "else" "end" "and" "with" "then"))

(defconst antenna-turtle--directions
  '("forward" "back" "left" "right" "up" "down"
    "roll-left" "roll-right"))

(defconst antenna-turtle--contextual-keywords
  '("title" "frequency" "max-length" "wire-diameter" "feed"))

(defconst antenna-turtle--feed-locations
  '("start" "center" "end"))

(defconst antenna-turtle--units
  '("meter" "meters" "centimeter" "centimeters"
    "millimeter" "millimeters" "inch" "inches" "foot" "feet"))

(defconst antenna-turtle--infix-word-operators
  '("or" "and" "bior" "bxor" "band" "not" "bnot"))

(defconst antenna-turtle--infix-symbol-operator-regexp
  (concat "\\(?:^\\|[[:space:]{]\\)"
          "\\(<=>\\|!=\\|>=\\|<=\\|<<\\|>>\\|[+*/%^=<>-]\\)"
          "\\(?:$\\|[[:space:]}]\\)"))

(defun antenna-turtle--operator-regexp (names)
  "Return a regexp matching one of NAMES in procedure position."
  (concat "(\\s-*\\(" (regexp-opt names) "\\)\\_>"))

(defconst antenna-turtle-font-lock-keywords
  `(("^\\(#lang\\)\\s-+\\(antenna-turtle\\)\\_>"
     (1 'font-lock-preprocessor-face)
     (2 'antenna-turtle-macro-face))
    (,(antenna-turtle--operator-regexp antenna-turtle--macros)
     1 'antenna-turtle-macro-face)
    (,(antenna-turtle--operator-regexp antenna-turtle--procedures)
     1 'antenna-turtle-api-face)
    (,(regexp-opt antenna-turtle--loop-clauses 'symbols)
     0 'antenna-turtle-loop-clause-face)
    (,(regexp-opt antenna-turtle--directions 'symbols)
     0 'antenna-turtle-direction-face)
    (,(regexp-opt antenna-turtle--contextual-keywords 'symbols)
     0 'antenna-turtle-loop-clause-face)
    (,(regexp-opt antenna-turtle--feed-locations 'symbols)
     0 'font-lock-constant-face)
    (,(regexp-opt antenna-turtle--units 'symbols)
     0 'font-lock-constant-face)
    (,(regexp-opt antenna-turtle--infix-word-operators 'symbols)
     0 'antenna-turtle-infix-operator-face)
    ("[{}]" 0 'antenna-turtle-infix-delimiter-face)
    (,antenna-turtle--infix-symbol-operator-regexp
     1 'antenna-turtle-infix-operator-face))
  "Additional font-lock rules for Antenna Turtle source files.")

(defun antenna-turtle--buffer-p ()
  "Return non-nil when the current buffer uses #lang antenna-turtle."
  (save-excursion
    (goto-char (point-min))
    (looking-at-p "[[:space:]]*#lang[ \t]+antenna-turtle\\_>")))

(defun antenna-turtle-scheme-setup ()
  "Add Antenna Turtle highlighting to the current Scheme buffer."
  (when (antenna-turtle--buffer-p)
    (font-lock-add-keywords nil antenna-turtle-font-lock-keywords 'prepend)))

;; Teach scheme-mode which arguments precede each macro body. These symbol
;; properties are global, but the names are specific to Antenna Turtle.
(put 'with-scale 'scheme-indent-function 1)
(put 'with-wire 'scheme-indent-function 0)
(put 'from-here 'scheme-indent-function 0)
(put 'with-pen 'scheme-indent-function 0)
(put 'with-push 'scheme-indent-function 0)

(add-hook 'scheme-mode-hook #'antenna-turtle-scheme-setup)

(provide 'antenna-turtle-emacs)

;;; antenna-turtle-emacs.el ends here
