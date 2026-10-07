;;; antenna-turtle-emacs.el --- Emacs support for Antenna Turtle -*- lexical-binding: t; -*-

;; Load this file from init.el after adjusting the path:
;;
;;   (load "C:/path/to/antenna-turtle/editors/antenna-turtle-emacs.el")
;;
;; It augments scheme-mode and racket-mode only in buffers whose first form is
;; `#lang antenna-turtle`.  Racket Mode remains an optional dependency.

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
  '("model-title" "model-impedance" "model-ground" "model-height"
    "real-ground" "maximum-segment-length" "snap-length" "model-frequency"
    "mmana-frequency" "wire-diameter"
    "frequency->wavelength" "wavelength->frequency" "model-wavelength"
    "span" "frequency-retuning-scale" "paraboloid" "cylinder" "dome" "bowl"
    "catenary"
    "wire-off" "wire-on" "here" "goto"
    "pen-up" "pen-down" "forward" "forwards"
    "back" "backward" "backwards" "move-nearest"
    "turn-x" "turn-y" "turn-z" "turn-axis"
    "scale" "scale-all" "push" "pop"
    "clear-wires" "reset-model!" "validate-model!" "current-position"
    "current-wire-diameter" "current-antenna-model"
    "model-vertices" "model-edges" "wire-used" "edge-length"
    "edge-segment-count"
    "export-nec2c" "export-mmana" "export-matlab"
    "export-matlab-loft" "show-model" "build-model"
    "nec2c-executable" "nec2c-measure-impedance" "nec2c-vswr-sweep"
    "nec2c-azimuth-pattern" "nec2c-elevation-pattern"
    "nec2c-radiation-grid" "parse-nec2c-output"
    "show-vswr-sweep" "show-return-loss-sweep" "show-impedance-sweep"
    "show-radiation-cut"
    "show-radiation-pattern-3d" "show-radiation-pattern-opengl"
    "show-radiation-comparison" "radiation-case" "radiation-case?"
    "radiation-case-title" "radiation-case-grid"
    "visualization-handle?" "visualization-update!" "visualization-show!"
    "visualization-close!" "visualization-open?"
    "vswr-sweep-renderers"
    "return-loss-sweep-renderers" "impedance-sweep-renderers"
    "radiation-cut-renderers"
    "radiation-grid-renderers"
    "nec2c-impedance-result-samples" "nec2c-impedance-result-run"
    "nec2c-sweep-result-frequencies" "nec2c-sweep-result-run"
    "nec2c-sweep-result-reference-impedance"
    "nec2c-sweep-frequency-frequency-mhz"
    "nec2c-sweep-frequency-feed-samples"
    "nec2c-sweep-sample-feedpoint" "nec2c-sweep-sample-vswr"
    "nec2c-sweep-sample-return-loss-db"
    "nec2c-sweep-sample-reflection-coefficient"
    "nec2c-feedpoint-sample-feed-name"
    "nec2c-feedpoint-sample-frequency-mhz"
    "nec2c-feedpoint-sample-voltage" "nec2c-feedpoint-sample-current"
    "nec2c-feedpoint-sample-impedance" "nec2c-feedpoint-sample-admittance"
    "nec2c-feedpoint-sample-input-power"
    "nec2c-pattern-samples" "nec2c-pattern-kind" "nec2c-pattern-fixed-angle"
    "nec2c-pattern-grid-samples" "nec2c-pattern-grid-theta-values"
    "nec2c-pattern-grid-phi-values"))

(defconst antenna-turtle--macros
  '("model" "move" "point" "spread" "feed" "turn" "reflect"
    "radial-repeat"
    "with-wire" "with-points" "from-here" "with-scale" "with-warp"
    "with-surface" "with-pen" "with-push"
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
  '("forward" "forwards" "back" "backward" "backwards"
    "left" "right" "up" "down"
    "roll-left" "roll-right"))

(defconst antenna-turtle--contextual-keywords
  '("title" "frequency" "impedance" "ground" "height" "max-length"
    "snaplen" "wire-diameter" "feed" "steps"))

(defconst antenna-turtle--feed-locations
  '("start" "center" "end"))

(defconst antenna-turtle--ground-kinds
  '("none" "perfect" "real"))

(defconst antenna-turtle--units
  '("wavelength" "half-wave" "quarter-wave" "radial-iterations"
    "meter" "meters" "centimeter" "centimeters"
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
    (,(regexp-opt antenna-turtle--ground-kinds 'symbols)
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

(defconst antenna-turtle--indentation-rules
  '((with-scale . 1)
    (with-warp . 1)
    (with-surface . 1)
    (radial-repeat . 1)
    (reflect . 1)
    (with-wire . 0)
    (with-points . 0)
    (from-here . 0)
    (with-pen . 0)
    (with-push . 0))
  "Body indentation rules shared by Scheme Mode and Racket Mode.")

(defun antenna-turtle--install-indentation-rules ()
  "Teach the active Lisp modes how Antenna Turtle bodies are shaped.

Emacs stores these rules on symbols rather than in buffers.  Installation is
therefore delayed until an Antenna Turtle buffer is seen.  The affected form
names are all specific to the Antenna Turtle DSL."
  (dolist (rule antenna-turtle--indentation-rules)
    (put (car rule) 'scheme-indent-function (cdr rule))
    ;; This property is harmless when the optional Racket Mode package is not
    ;; installed, and is its documented indentation extension point when it is.
    (put (car rule) 'racket-indent-function (cdr rule))))

(defun antenna-turtle-setup ()
  "Add Antenna Turtle editing support to the current source buffer.

Do nothing unless the buffer begins with `#lang antenna-turtle`."
  (interactive)
  (when (antenna-turtle--buffer-p)
    (antenna-turtle--install-indentation-rules)
    ;; Removing first makes the command safe to rerun interactively.
    (font-lock-remove-keywords nil antenna-turtle-font-lock-keywords)
    (font-lock-add-keywords nil antenna-turtle-font-lock-keywords 'prepend)
    (when font-lock-mode
      (font-lock-flush)
      (font-lock-ensure))))

(defalias 'antenna-turtle-scheme-setup #'antenna-turtle-setup)

(add-hook 'scheme-mode-hook #'antenna-turtle-setup)
(add-hook 'racket-mode-hook #'antenna-turtle-setup)

;; Loading this helper after visiting a source file should not require the user
;; to re-enter either major mode merely to install and refresh its font lock.
(dolist (buffer (buffer-list))
  (with-current-buffer buffer
    (when (or (derived-mode-p 'scheme-mode)
              (derived-mode-p 'racket-mode))
      (antenna-turtle-setup))))

(provide 'antenna-turtle-emacs)

;;; antenna-turtle-emacs.el ends here
