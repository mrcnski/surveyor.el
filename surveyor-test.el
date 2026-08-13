;;; surveyor-test.el --- Tests for surveyor.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Marcin Swieczkowski

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -l surveyor-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Allow running under `emacs -Q' without gptel installed; surveyor only
;; calls gptel functions at runtime, never at load time.
(unless (require 'gptel nil t)
  (provide 'gptel))

(add-to-list 'load-path
             (file-name-directory (or load-file-name buffer-file-name)))
(require 'surveyor)

;;;; surveyor-extract-source

(ert-deftest surveyor-extract-fenced ()
  "Extracts a matching fenced block surrounded by prose."
  (should (equal (surveyor-extract-source
                  "Here you go:\n```mermaid\nflowchart TD\n  A --> B\n```\nEnjoy!"
                  "mermaid")
                 "flowchart TD\n  A --> B")))

(ert-deftest surveyor-extract-first-fence ()
  "With multiple fences, extracts the first."
  (should (equal (surveyor-extract-source
                  "```d2\na -> b\n```\ntext\n```d2\nc -> d\n```"
                  "d2")
                 "a -> b")))

(ert-deftest surveyor-extract-any-fence-fallback ()
  "Falls back to any fenced block when the tag doesn't match."
  (should (equal (surveyor-extract-source
                  "```\ndigraph { a -> b }\n```" "dot")
                 "digraph { a -> b }")))

(ert-deftest surveyor-extract-bare ()
  "Accepts a bare response matching the engine's declaration regexp."
  (should (equal (surveyor-extract-source
                  "sequenceDiagram\n  A->>B: hi" "mermaid"
                  "\\(?:flowchart\\|sequenceDiagram\\)")
                 "sequenceDiagram\n  A->>B: hi")))

(ert-deftest surveyor-extract-no-bare-without-re ()
  "Rejects a bare response when the engine has no declaration regexp."
  (should-not (surveyor-extract-source "a -> b" "d2")))

(ert-deftest surveyor-extract-none ()
  (should-not (surveyor-extract-source "I cannot draw that." "mermaid"
                                       "\\(?:flowchart\\)")))

;;;; surveyor--clip

(ert-deftest surveyor-clip-truncates ()
  (let ((surveyor-max-code-chars 10))
    (should (equal (surveyor--clip "0123456789abcdef")
                   "0123456789\n[remaining code truncated]"))))

(ert-deftest surveyor-clip-passthrough ()
  (should (equal (surveyor--clip "short") "short")))

;;;; surveyor--build-prompt

(defun surveyor-test--engine (name)
  "Return engine plist for NAME."
  (alist-get name surveyor-engines))

(ert-deftest surveyor-build-prompt-includes-parts ()
  (let ((prompt (surveyor--build-prompt
                 (list :kind 'flowchart :code "(defun f () 1)"
                       :symbols '("f" "g") :mode 'emacs-lisp-mode)
                 (surveyor-test--engine 'mermaid))))
    (should (string-match-p "Diagram kind: flowchart" prompt))
    (should (string-match-p "- f\n- g" prompt))
    (should (string-match-p "(defun f () 1)" prompt))
    (should (string-match-p "emacs-lisp-mode" prompt))))

(ert-deftest surveyor-build-prompt-no-symbols ()
  "No imenu section when the context has no symbols."
  (should-not (string-match-p
               "imenu"
               (surveyor--build-prompt
                (list :kind 'class :code "x" :symbols nil :mode 'text-mode)
                (surveyor-test--engine 'mermaid)))))

;;;; Engine definitions

(ert-deftest surveyor-engines-well-formed ()
  "Every engine has the required keys and non-empty kinds."
  (dolist (entry surveyor-engines)
    (let ((plist (cdr entry)))
      (dolist (key '(:fence :in-ext :out-ext :program :render-args :syntax :kinds))
        (should (plist-member plist key)))
      (should (fboundp (plist-get plist :program)))
      (should (fboundp (plist-get plist :render-args)))
      (should (consp (plist-get plist :kinds)))
      (dolist (kind (plist-get plist :kinds))
        (should (stringp (cdr kind)))))))

(ert-deftest surveyor-engine-order-covered ()
  "Every auto-order engine is defined."
  (dolist (name surveyor--engine-order)
    (should (alist-get name surveyor-engines))))

(ert-deftest surveyor-mermaid-npx-only-when-explicit ()
  "The npx fallback needs an explicit `surveyor-engine' setting."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (cmd) (when (equal cmd "npx") "/usr/bin/npx"))))
    (should-not (surveyor--mermaid-program))
    (should (equal (surveyor--mermaid-program t)
                   '("npx" "-y" "@mermaid-js/mermaid-cli")))))

(ert-deftest surveyor-mermaid-mmdc-always-offered ()
  "An installed mmdc is used regardless of explicitness."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (cmd) (when (equal cmd "mmdc") "/usr/local/bin/mmdc"))))
    (should (equal (surveyor--mermaid-program) '("mmdc")))))

(ert-deftest surveyor-menu-arg ()
  "Extracts a transient argument value by key prefix."
  (should (equal (surveyor--menu-arg '("--kind=sequence" "--engine=d2")
                                     "--kind=")
                 "sequence"))
  (should-not (surveyor--menu-arg '("--engine=d2") "--kind=")))

(ert-deftest surveyor-menu-covers-all-kinds-and-engines ()
  (should (equal (surveyor--all-kinds) '("flowchart" "sequence" "class")))
  (should (equal (surveyor--engine-names) '("auto" "d2" "mermaid" "dot")))
  (should (equal (surveyor--level-names) '("code" "logical"))))

(ert-deftest surveyor-save-default-name-includes-level ()
  "A logical diagram saves under a name distinct from the code one."
  (with-temp-buffer
    (setq-local surveyor--context '(:name "foo.el" :kind flowchart
                                          :level logical)
                surveyor--file "/tmp/surveyor-abc123.svg")
    (should (equal (surveyor--save-default-name)
                   "foo.el-logical-flowchart.svg"))))

(ert-deftest surveyor-run-rejects-unsupported-kind ()
  "A menu kind the resolved engine cannot draw signals a user-error."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (cmd) (when (equal cmd "dot") "/usr/bin/dot"))))
    (should-error (surveyor--run #'ignore 'class 'dot) :type 'user-error)))

(ert-deftest surveyor-auto-never-picks-npx-mermaid ()
  "With only npx installed, auto errors instead of picking mermaid."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (cmd) (when (equal cmd "npx") "/usr/bin/npx"))))
    (let ((surveyor-engine 'auto))
      (should-error (surveyor--resolve-engine) :type 'user-error))
    (let ((surveyor-engine 'mermaid))
      (should (eq (car (surveyor--resolve-engine)) 'mermaid)))))

(ert-deftest surveyor-system-prompt-uses-fence ()
  (should (string-match-p "```d2"
                          (surveyor--system-prompt
                           (surveyor-test--engine 'd2)
                           (surveyor--level 'code)))))

;;;; Levels

(ert-deftest surveyor-levels-well-formed ()
  "Every level has a node budget and a naming rule."
  (dolist (entry surveyor-levels)
    (let ((level (cdr entry)))
      (should (natnump (plist-get level :nodes)))
      (should (stringp (plist-get level :naming))))))

(ert-deftest surveyor-level-defaults-to-code ()
  (should (eq surveyor-level 'code))
  (should (equal (surveyor--level nil) (surveyor--level 'code)))
  (should-not (surveyor--level 'nonesuch)))

(ert-deftest surveyor-level-default-is-configurable ()
  "`surveyor-level' drives both the fallback and the name qualification."
  (let ((surveyor-level 'logical))
    (should (equal (surveyor--level nil) (surveyor--level 'logical)))
    ;; With `logical' as the default it is the unmarked case, and `code' is not.
    (should (equal (surveyor--kind-label '(:kind flowchart :level logical))
                   "flowchart"))
    (should (equal (surveyor--kind-label '(:kind flowchart :level code))
                   "code flowchart")))
  ;; Every offered level is a valid customize choice.
  (let ((choices (cdr (get 'surveyor-level 'custom-type))))
    (should (equal (sort (mapcar (lambda (c) (car (last c))) choices) #'string<)
                   (sort (mapcar #'car surveyor-levels) #'string<)))))

(ert-deftest surveyor-code-level-prompts-unchanged ()
  "The `code' level reproduces the original, pre-level prompts exactly."
  (let* ((engine (surveyor-test--engine 'mermaid))
         (context (list :kind 'flowchart :code "(defun f () 1)"
                        :symbols '("f") :mode 'emacs-lisp-mode :level 'code))
         (system (surveyor--system-prompt engine (surveyor--level 'code))))
    ;; No level instruction is added.
    (should (equal (surveyor--build-prompt context engine)
                   (concat
                    (format "Diagram kind: flowchart.  %s\n\n"
                            (alist-get 'flowchart (plist-get engine :kinds)))
                    "Definitions in this file (ground truth, from imenu):\n"
                    "- f\n\n"
                    "Language: emacs-lisp-mode\n\n"
                    "Source:\n```\n(defun f () 1)\n```\n")))
    (should (string-match-p "use their real names as labels" system))
    (should (string-match-p "at most about 25 nodes" system))))

(ert-deftest surveyor-logical-level-relaxes-naming-and-budget ()
  "The logical level drops the real-names rule and tightens the node budget."
  (let ((system (surveyor--system-prompt (surveyor-test--engine 'mermaid)
                                         (surveyor--level 'logical))))
    (should-not (string-match-p "use their real names as labels" system))
    (should (string-match-p "problem domain" system))
    (should (string-match-p "at most about 12 nodes" system))))

(ert-deftest surveyor-logical-level-adds-instruction ()
  "The logical level adds guidance the code level does not."
  (let* ((context (list :kind 'flowchart :code "x" :symbols nil
                        :mode 'text-mode))
         (engine (surveyor-test--engine 'mermaid))
         (code (surveyor--build-prompt context engine))
         (logical (surveyor--build-prompt
                   (append context '(:level logical)) engine)))
    (should (string-match-p "at a high level" logical))
    (should-not (string-match-p "at a high level" code))
    ;; Both still carry the kind instruction and the source.
    (should (string-match-p "Diagram kind: flowchart" logical))))

(ert-deftest surveyor-kind-label-qualifies-non-default-level ()
  "Only a non-default level shows up in buffer and file names."
  (should (equal (surveyor--kind-label '(:kind flowchart)) "flowchart"))
  (should (equal (surveyor--kind-label '(:kind flowchart :level code))
                 "flowchart"))
  (should (equal (surveyor--kind-label '(:kind flowchart :level logical))
                 "logical flowchart")))

(ert-deftest surveyor-run-rejects-unknown-level ()
  (cl-letf (((symbol-function 'executable-find)
             (lambda (cmd) (when (equal cmd "d2") "/usr/local/bin/d2"))))
    (should-error (surveyor--run #'ignore 'flowchart 'd2 'nonesuch)
                  :type 'user-error)))

;;;; View buffer

(ert-deftest surveyor-save-default-name ()
  "Default save name combines context name, kind, and image extension."
  (with-temp-buffer
    (setq-local surveyor--context '(:name "foo/bar baz.el" :kind flowchart)
                surveyor--file "/tmp/surveyor-abc123.svg")
    (should (equal (surveyor--save-default-name)
                   "foo-bar-baz.el-flowchart.svg"))))

(ert-deftest surveyor-diagram-mode-header-line ()
  "The diagram minor mode advertises its keys in the header line."
  (with-temp-buffer
    (surveyor-diagram-mode 1)
    (should (stringp header-line-format))
    (dolist (part '("g regenerate" "s source" "w copy" "S save"
                    "E open" "zoom" "0 refit" "q quit"))
      (should (string-search part header-line-format)))))

(provide 'surveyor-test)
;;; surveyor-test.el ends here
