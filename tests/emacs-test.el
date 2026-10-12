;;; emacs-test.el --- Editor tests for Antenna Turtle -*- lexical-binding: t; -*-

(require 'ert)
(require 'scheme)

(load-file
 (expand-file-name "../editors/antenna-turtle-emacs.el"
                   (file-name-directory (or load-file-name buffer-file-name))))

(defun antenna-turtle-test--face-at (word occurrence)
  (goto-char (point-min))
  (dotimes (_ occurrence)
    (re-search-forward (concat "\\_<" (regexp-quote word) "\\_>")))
  (get-text-property (- (point) (length word)) 'face))

(ert-deftest antenna-turtle-solid-font-lock ()
  (with-temp-buffer
    (scheme-mode)
    (setq-local indent-tabs-mode nil)
    (insert "#lang antenna-turtle\n"
            "(define ordinary-length (length values))\n"
            "(cuboid substrate\n"
            "  length 150\n"
            "  material pec\n"
            "  anchor bottom)\n"
            "(mesh-point)\n"
            "(mesh-plane xy)\n"
            "(lumped-element up name load resistance (* 50 ohms) gap 1 size '(2 2))\n"
            "(simulate engine openems sweep '(800 1050) profile draft)\n")
    (antenna-turtle-setup)
    (font-lock-ensure)
    (should (eq (antenna-turtle-test--face-at "cuboid" 1)
                'antenna-turtle-macro-face))
    (should-not (eq (antenna-turtle-test--face-at "length" 1)
                    'antenna-turtle-loop-clause-face))
    (should (eq (antenna-turtle-test--face-at "length" 2)
                'antenna-turtle-loop-clause-face))
    (should (eq (antenna-turtle-test--face-at "profile" 1)
                'antenna-turtle-loop-clause-face))
    (should (eq (antenna-turtle-test--face-at "mesh-plane" 1)
                'antenna-turtle-macro-face))
    (should (eq (antenna-turtle-test--face-at "lumped-element" 1)
                'antenna-turtle-macro-face))
    (should (eq (antenna-turtle-test--face-at "resistance" 1)
                'antenna-turtle-loop-clause-face))
    (should (eq (antenna-turtle-test--face-at "ohms" 1)
                'font-lock-constant-face))
    (should (eq (antenna-turtle-test--face-at "xy" 1)
                'font-lock-constant-face))
    (should (eq (antenna-turtle-test--face-at "draft" 1)
                'font-lock-constant-face))))

(ert-deftest antenna-turtle-solid-indentation ()
  (with-temp-buffer
    (scheme-mode)
    (setq-local indent-tabs-mode nil)
    (insert "#lang antenna-turtle\n"
            "(with-material fr4\n"
            "(cuboid substrate\n"
            "size '(150 150 1.6)\n"
            "anchor bottom))\n"
            "(sheet rect ground\n"
            "size '(150 150)\n"
            "mesh-edges exact)\n"
            "(sheet legacy\n"
            "points outline\n"
            "material pec)\n"
            "(lumped-element up\n"
            "name load\n"
            "resistance (* 50 ohms)\n"
            "gap 1\n"
            "size '(2 2))\n"
            "(simulate engine openems\n"
            "sweep '(800 1050)\n"
            "profile draft)\n")
    (antenna-turtle-setup)
    (indent-region (point-min) (point-max))
    (should
     (equal
      (buffer-string)
      (concat
       "#lang antenna-turtle\n"
       "(with-material fr4\n"
       "  (cuboid substrate\n"
       "    size '(150 150 1.6)\n"
       "    anchor bottom))\n"
       "(sheet rect ground\n"
       "  size '(150 150)\n"
       "  mesh-edges exact)\n"
       "(sheet legacy\n"
       "  points outline\n"
       "  material pec)\n"
       "(lumped-element up\n"
       "  name load\n"
       "  resistance (* 50 ohms)\n"
       "  gap 1\n"
       "  size '(2 2))\n"
       "(simulate engine openems\n"
       "          sweep '(800 1050)\n"
       "          profile draft)\n")))))

;;; emacs-test.el ends here
