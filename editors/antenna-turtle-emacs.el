;;; antenna-turtle-emacs.el --- Emacs support for Antenna Turtle -*- lexical-binding: t; -*-

;; Load this file from init.el after adjusting the path:
;;
;;   (load "C:/path/to/antenna-turtle/editors/antenna-turtle-emacs.el")
;;
;; The native macOS installer generates a complete bootstrap at
;; .local/macos/antenna-turtle-env.el; macOS users should load only that file.
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
    "span" "frequency-retuning-scale" "paraboloid" "dome" "bowl"
    "catenary"
    "wire-off" "wire-on" "here" "goto"
    "pen-up" "pen-down" "forward" "forwards"
    "back" "backward" "backwards" "move-nearest"
    "turn-x" "turn-y" "turn-z" "turn-axis"
    "scale-all" "push" "pop"
    "clear-wires" "reset-model!" "validate-model!" "current-position"
    "current-wire-diameter" "current-antenna-model"
    "model-vertices" "model-edges" "wire-used" "edge-length"
    "edge-segment-count"
    "export-nec2c" "export-mmana" "export-matlab"
    "export-matlab-loft" "show-model" "show-solid-model" "build-model"
    "add-body" "add-sheet" "add-lumped-port" "add-lumped-element" "clear-bodies"
    "model-bodies" "model-sheets" "model-ports" "model-components"
    "validate-solid-scene!"
    "make-dielectric" "make-conductor" "conducting-sheet-material"
    "material-default-precedence" "read-stl-solid" "mesh-point"
    "derive-simulation-profile" "radiation-pattern"
    "power-budget" "format-power-budget" "display-power-budget"
    "measurement-frequencies" "measurement-frequency-range" "measurement-ports"
    "impedance-at" "admittance-at" "resistance-at" "reactance-at"
    "reflection-at" "s11-db-at" "return-loss-at" "vswr-at"
    "s-parameter-at" "s-parameter-db-at" "s-parameter-phase-at"
    "gain-at" "maximum-gain" "maximum-gain-direction"
    "front-to-back-ratio" "front-to-side-ratio"
    "axial-ratio-at" "polarization-tilt-at" "polarization-sense-at"
    "e-field-at" "pattern-angular-resolution"
    "openems-sweep" "openems-load-artifacts" "openems-radiation-grid"
    "openems-sweep->network-sweep" "openems-close!"
    "openems-power-budget?" "openems-power-budget-frequency-mhz"
    "openems-power-budget-excitation-port"
    "openems-power-budget-incident-power-w"
    "openems-power-budget-reflected-power-w"
    "openems-power-budget-accepted-power-w"
    "openems-power-budget-delivered-power-w"
    "openems-power-budget-radiated-power-w"
    "openems-power-budget-dielectric-power-w"
    "openems-power-budget-lumped-power-w"
    "openems-power-budget-conductor-and-unaccounted-power-w"
    "nec2c-executable" "nec2c-measure-impedance" "nec2c-vswr-sweep"
    "nec2c-azimuth-pattern" "nec2c-elevation-pattern"
    "nec2c-radiation-grid" "parse-nec2c-output"
    "write-html-report" "write-nec2c-html-report" "write-openems-html-report"
    "show-vswr-sweep" "show-return-loss-sweep" "show-impedance-sweep"
    "show-smith-chart"
    "show-radiation-cut"
    "show-radiation-pattern-3d" "show-radiation-pattern-opengl"
    "show-radiation-comparison" "radiation-case" "radiation-case?"
    "radiation-case-title" "radiation-case-grid"
    "visualization-handle?" "visualization-update!" "visualization-show!"
    "visualization-close!" "visualization-open?"
    "vswr-sweep-renderers"
    "return-loss-sweep-renderers" "impedance-sweep-renderers"
    "smith-chart-renderers"
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
    "with-surface" "with-pen" "with-push" "with-material" "with-body"
    "with-traces"
    "union" "difference" "intersect" "hull" "scale"
    "body" "sheet" "port" "lumped-element" "dielectric" "conductor" "mesh-plane"
    "cuboid" "sphere" "cylinder" "capsule" "stl" "simulate"
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

;; These setting names include ordinary Racket identifiers such as `length`,
;; `name`, and `path`. Match them only as direct children of the corresponding
;; pair-wise DSL forms instead of coloring every occurrence in the buffer.
(defconst antenna-turtle--solid-contextual-keywords
  '("geometry" "material" "priority" "precedence" "coordinates" "anchor"
    "points" "mesh-edges" "size" "length" "width" "height"
    "radius" "diameter" "segments" "name" "er" "ur"
    "relative-permittivity" "relative-permeability" "loss-tangent"
    "loss-frequency" "conductivity" "sheet-thickness" "thickness" "metal-thickness"
    "gap" "depth" "path" "join" "miter-limit"
    "resistance" "inductance" "capacitance" "topology" "caps"
    "engine" "sweep" "profile" "octave" "keep-artifacts" "progress"
    "timeout"))

(defconst antenna-turtle--pairwise-forms
  '("body" "with-body" "with-traces" "sheet" "port" "lumped-element" "dielectric" "conductor" "cuboid" "sphere" "cylinder"
    "capsule" "stl" "simulate"))

(defconst antenna-turtle--solid-values
  '("pec" "silver" "copper" "gold" "aluminum" "brass" "steel"
    "air" "fr4" "ptfe" "teflon"
    "rogers-4003c" "rogers-4350b" "rogers-5880"
    "rect" "exact" "metal" "local" "world" "xy" "xz" "yz"
    "origin" "top" "bottom" "front" "start" "center" "end"
    "draft" "standard" "openems"
    "series" "parallel" "miter" "bevel"))

(defconst antenna-turtle--feed-locations
  '("start" "center" "end"))

(defconst antenna-turtle--ground-kinds
  '("none" "perfect" "real"))

(defconst antenna-turtle--units
  '("wavelength" "half-wave" "quarter-wave" "radial-iterations"
    "meter" "meters" "centimeter" "centimeters"
    "millimeter" "millimeters" "inch" "inches" "foot" "feet"
    "ohm" "ohms" "kiloohm" "kiloohms" "megaohm" "megaohms"
    "henry" "henries" "millihenry" "millihenries"
    "microhenry" "microhenries" "nanohenry" "nanohenries"
    "farad" "farads" "millifarad" "millifarads"
    "microfarad" "microfarads" "nanofarad" "nanofarads"
    "picofarad" "picofarads"))

(defconst antenna-turtle--infix-word-operators
  '("or" "and" "bior" "bxor" "band" "not" "bnot"))

(defconst antenna-turtle--infix-symbol-operator-regexp
  (concat "\\(?:^\\|[[:space:]{]\\)"
          "\\(<=>\\|!=\\|>=\\|<=\\|<<\\|>>\\|[+*/%^=<>-]\\)"
          "\\(?:$\\|[[:space:]}]\\)"))

(defconst antenna-turtle--solid-contextual-keyword-regexp
  (regexp-opt antenna-turtle--solid-contextual-keywords 'symbols))

(defun antenna-turtle--inside-pairwise-form-p (position)
  "Return non-nil when POSITION is directly inside a pair-wise DSL form."
  (save-excursion
    (goto-char position)
    (let ((open (nth 1 (syntax-ppss))))
      (when open
        (goto-char (1+ open))
        (skip-chars-forward " \t\r\n")
        (let ((start (point)))
          (condition-case nil
              (progn
                (forward-sexp 1)
                (member (buffer-substring-no-properties start (point))
                        antenna-turtle--pairwise-forms))
            (scan-error nil)))))))

(defun antenna-turtle--solid-contextual-keyword-matcher (limit)
  "Find the next solid-DSL setting name before LIMIT."
  (catch 'matched
    (while (re-search-forward
            antenna-turtle--solid-contextual-keyword-regexp limit t)
      (when (antenna-turtle--inside-pairwise-form-p (match-beginning 0))
        (throw 'matched t)))
    nil))

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
    (antenna-turtle--solid-contextual-keyword-matcher
     0 'antenna-turtle-loop-clause-face)
    (,(regexp-opt antenna-turtle--feed-locations 'symbols)
     0 'font-lock-constant-face)
    (,(regexp-opt antenna-turtle--ground-kinds 'symbols)
     0 'font-lock-constant-face)
    (,(regexp-opt antenna-turtle--solid-values 'symbols)
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

(defun antenna-turtle--pairwise-indent (&rest arguments)
  "Indent a pair-wise DSL continuation two spaces past its opening form.

Scheme Mode calls custom indentation with STATE first and Racket Mode calls it
with INDENT-POINT first, so accept both documented conventions."
  (let ((state (if (listp (car arguments))
                   (car arguments)
                 (cadr arguments))))
    (save-excursion
      (goto-char (elt state 1))
      (+ (current-column) 2))))

(defconst antenna-turtle--indentation-rules
  '((with-scale . 1)
    (with-material . 1)
    (with-body . 1)
    (with-traces . 1)
    (union . 0)
    (difference . 0)
    (intersect . 0)
    (hull . 0)
    (scale . 1)
    (with-warp . 1)
    (with-surface . 1)
    (radial-repeat . 1)
    (reflect . 1)
    (with-wire . 0)
    (with-points . 0)
    (from-here . 0)
    (with-pen . 0)
    (with-push . 0)
    ;; Pair-wise declarations keep their identifying positional arguments on
    ;; the first line and align subsequent setting/value pairs as a body.
    (body . 1)
    (sheet . antenna-turtle--pairwise-indent)
    (port . 1)
    (lumped-element . 1)
    (dielectric . 0)
    (conductor . 0)
    (cuboid . 1)
    (sphere . 1)
    (cylinder . 1)
    (capsule . 1)
    (stl . 1)
    (simulate . 0))
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
