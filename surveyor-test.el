;;; surveyor-test.el --- Tests for surveyor.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Marcin Swieczkowski

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -l surveyor-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)

;; Allow running under `emacs -Q' without gptel installed; surveyor only
;; calls gptel functions at runtime, never at load time.
(unless (require 'gptel nil t)
  (provide 'gptel))

(add-to-list 'load-path
             (file-name-directory (or load-file-name buffer-file-name)))
(require 'surveyor)

;;;; surveyor-extract-mermaid

(ert-deftest surveyor-extract-fenced ()
  "Extracts a fenced mermaid block surrounded by prose."
  (should (equal (surveyor-extract-mermaid
                  "Here you go:\n```mermaid\nflowchart TD\n  A --> B\n```\nEnjoy!")
                 "flowchart TD\n  A --> B")))

(ert-deftest surveyor-extract-first-fence ()
  "With multiple fences, extracts the first."
  (should (equal (surveyor-extract-mermaid
                  "```mermaid\ngraph LR\n A-->B\n```\ntext\n```mermaid\ngraph LR\n C-->D\n```")
                 "graph LR\n A-->B")))

(ert-deftest surveyor-extract-bare ()
  "Accepts a bare response starting with a diagram declaration."
  (should (equal (surveyor-extract-mermaid "sequenceDiagram\n  A->>B: hi")
                 "sequenceDiagram\n  A->>B: hi")))

(ert-deftest surveyor-extract-none ()
  "Returns nil when the response contains no diagram."
  (should-not (surveyor-extract-mermaid "I cannot draw that.")))

;;;; surveyor--clip

(ert-deftest surveyor-clip-truncates ()
  (let ((surveyor-max-code-chars 10))
    (should (equal (surveyor--clip "0123456789abcdef")
                   "0123456789\n[remaining code truncated]"))))

(ert-deftest surveyor-clip-passthrough ()
  (should (equal (surveyor--clip "short") "short")))

;;;; surveyor--build-prompt

(ert-deftest surveyor-build-prompt-includes-parts ()
  (let ((prompt (surveyor--build-prompt
                 (list :kind 'flowchart :code "(defun f () 1)"
                       :symbols '("f" "g") :mode 'emacs-lisp-mode))))
    (should (string-match-p "Diagram kind: flowchart" prompt))
    (should (string-match-p "- f\n- g" prompt))
    (should (string-match-p "(defun f () 1)" prompt))
    (should (string-match-p "emacs-lisp-mode" prompt))))

(ert-deftest surveyor-build-prompt-no-symbols ()
  "No imenu section when the context has no symbols."
  (should-not (string-match-p
               "imenu"
               (surveyor--build-prompt
                (list :kind 'class :code "x" :symbols nil :mode 'text-mode)))))

;;;; surveyor-kinds

(ert-deftest surveyor-kinds-have-instructions ()
  (dolist (kind '(flowchart sequence class))
    (should (stringp (alist-get kind surveyor-kinds)))))

(provide 'surveyor-test)
;;; surveyor-test.el ends here
