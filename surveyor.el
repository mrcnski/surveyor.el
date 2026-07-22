;;; surveyor.el --- Survey your code with LLM-generated diagrams -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Marcin Swieczkowski

;; Author: Marcin Swieczkowski <marcin@realemail.net>
;; Assisted-by: Claude:claude-fable-5
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (gptel "0.9.0"))
;; Keywords: convenience, tools, docs
;; URL: https://github.com/mrcnski/surveyor.el

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Surveyor generates diagrams of the code you are looking at, using your
;; configured LLM (via gptel).  Pick a scope (defun or file) and a diagram
;; kind (flowchart, sequence, class); Surveyor grounds the prompt in
;; structural facts (imenu symbols), asks the LLM for Mermaid source,
;; validates it by rendering with mermaid-cli, feeds renderer errors back
;; to the LLM for automatic repair, and displays the image in a view
;; buffer.
;;
;; Entry points: `surveyor-defun' and `surveyor-file'.
;;
;; In the view buffer: `g' regenerates, `s' shows the Mermaid source,
;; `w' copies it, `q' quits.
;;
;; Window placement respects `display-buffer-alist'.  Match on
;; (category . surveyor) on Emacs 30+, on the buffer name prefix
;; "*surveyor", or on `surveyor-view-mode'; or set
;; `surveyor-display-action' to bypass the alist entirely.
;;
;; Rendering requires the Mermaid CLI: `mmdc' if installed, otherwise
;; "npx -y @mermaid-js/mermaid-cli".  The render step is synchronous
;; (typically 1-3s); the LLM request is asynchronous.

;;; Code:

(require 'cl-lib)
(require 'imenu)
(require 'add-log)
(require 'gptel)

(defgroup surveyor nil
  "LLM-generated diagrams of your code."
  :group 'tools
  :prefix "surveyor-")

(defcustom surveyor-mmdc-command "mmdc"
  "Mermaid CLI executable used to validate and render diagrams.
When it is not found, Surveyor falls back to
\"npx -y @mermaid-js/mermaid-cli\"."
  :type 'string)

(defcustom surveyor-max-repair-attempts 2
  "How many times to feed renderer errors back to the LLM for repair."
  :type 'natnum)

(defcustom surveyor-image-scale 2
  "Scale factor passed to mermaid-cli.
Higher values render crisper images on HiDPI displays."
  :type 'natnum)

(defcustom surveyor-max-code-chars 100000
  "Maximum number of code characters included in a prompt.
Longer code is truncated with a note to the LLM."
  :type 'natnum)

(defcustom surveyor-display-action nil
  "When non-nil, the `display-buffer' action for surveyor view buffers.
This overrides any `display-buffer-alist' matching.  When nil, the
view buffer is displayed with the action category `surveyor', which
`display-buffer-alist' entries can match on (Emacs 30+)."
  :type '(choice (const :tag "Use display-buffer-alist" nil) sexp))

(defconst surveyor-kinds
  '((flowchart . "Draw a flowchart (`flowchart TD') of the control flow:
branches, loops, early returns and error paths.  Collapse straight-line
statements into single nodes.")
    (sequence . "Draw a `sequenceDiagram' of the interactions: the
participants are the functions, objects or services involved; the
messages are the calls between them, in the order they happen.")
    (class . "Draw a `classDiagram' of the structure: the types, classes
or modules with their key fields and methods, and the relationships
between them (inheritance, composition, use)."))
  "Alist of diagram kind to LLM instruction.")

(defconst surveyor--system-prompt
  "You generate Mermaid diagrams from source code.
Reply with exactly one fenced code block: ```mermaid ... ```
No prose before or after it.
Only include nodes for things that exist in the provided code or symbol
list, and use their real names as labels.
Keep the diagram readable: at most about 25 nodes; use subgraphs to
group related nodes when helpful.
Do not use HTML in labels."
  "System prompt sent with every diagram request.")

;;;; Context collection

(defun surveyor--imenu-symbols ()
  "Return a flat list of symbol names from imenu, or nil."
  (ignore-errors
    (let (names)
      (cl-labels ((walk (items)
                    (dolist (item items)
                      (cond ((imenu--subalist-p item) (walk (cdr item)))
                            ((stringp (car item)) (push (car item) names))))))
        (walk (imenu--make-index-alist t)))
      (nreverse names))))

(defun surveyor--defun-context ()
  "Collect the defun at point as a diagram context plist."
  (let ((bounds (bounds-of-thing-at-point 'defun)))
    (unless bounds
      (user-error "No defun at point"))
    (list :name (or (add-log-current-defun) "defun")
          :code (buffer-substring-no-properties (car bounds) (cdr bounds))
          :symbols nil
          :mode major-mode)))

(defun surveyor--file-context ()
  "Collect the current buffer as a diagram context plist."
  (list :name (if buffer-file-name
                  (file-name-nondirectory buffer-file-name)
                (buffer-name))
        :code (buffer-substring-no-properties (point-min) (point-max))
        :symbols (surveyor--imenu-symbols)
        :mode major-mode))

;;;; Prompt building

(defun surveyor--clip (code)
  "Truncate CODE to `surveyor-max-code-chars', noting the cut."
  (if (> (length code) surveyor-max-code-chars)
      (concat (substring code 0 surveyor-max-code-chars)
              "\n[remaining code truncated]")
    code))

(defun surveyor--build-prompt (context)
  "Build the LLM prompt string for CONTEXT."
  (let ((kind (plist-get context :kind)))
    (concat
     (format "Diagram kind: %s.  %s\n\n" kind (alist-get kind surveyor-kinds))
     (when-let* ((symbols (plist-get context :symbols)))
       (format "Definitions in this file (ground truth, from imenu):\n%s\n\n"
               (mapconcat (lambda (s) (concat "- " s)) symbols "\n")))
     (format "Language: %s\n\nSource:\n```\n%s\n```\n"
             (plist-get context :mode)
             (surveyor--clip (plist-get context :code))))))

;;;; Mermaid extraction and rendering

(defun surveyor-extract-mermaid (response)
  "Extract Mermaid source from LLM RESPONSE, or return nil.
Accepts a fenced ```mermaid block, or a bare response that starts
with a known diagram declaration."
  (cond
   ((string-match "```mermaid[ \t]*\n\\(\\(?:.\\|\n\\)*?\\)\n?```" response)
    (string-trim (match-string 1 response)))
   ((string-match (concat "\\`[ \t\n]*\\(\\(?:flowchart\\|graph\\|sequenceDiagram\\|"
                          "classDiagram\\|stateDiagram\\|erDiagram\\)"
                          "\\(?:.\\|\n\\)*\\)\\'")
                  response)
    (string-trim (match-string 1 response)))))

(defun surveyor--mmdc-program ()
  "Return the mermaid-cli invocation as a list of strings."
  (cond
   ((executable-find surveyor-mmdc-command)
    (list surveyor-mmdc-command))
   ((executable-find "npx")
    (list "npx" "-y" "@mermaid-js/mermaid-cli"))
   (t (user-error "Neither `%s' nor `npx' found; install mermaid-cli"
                  surveyor-mmdc-command))))

(defun surveyor--render (source)
  "Render Mermaid SOURCE to a PNG file.
Return (:file FILE) on success or (:error STRING) on failure."
  (let ((in (make-temp-file "surveyor-" nil ".mmd" source))
        (out (make-temp-file "surveyor-" nil ".png"))
        (program (surveyor--mmdc-program)))
    (unwind-protect
        (with-temp-buffer
          (let ((status (apply #'call-process (car program) nil t nil
                               (append (cdr program)
                                       (list "-i" in "-o" out
                                             "-s" (number-to-string surveyor-image-scale)
                                             "-b" "white")))))
            (if (and (eql status 0)
                     (> (file-attribute-size (file-attributes out)) 0))
                (list :file out)
              (list :error (buffer-string)))))
      (delete-file in))))

;;;; Request and repair loop

(defun surveyor--request (context prompt attempt)
  "Send PROMPT for CONTEXT to the LLM; ATTEMPT counts repair rounds."
  (message "surveyor: asking LLM (%s)..." (plist-get context :kind))
  (gptel-request prompt
    :system surveyor--system-prompt
    :callback
    (lambda (response info)
      (if (not (stringp response))
          (message "surveyor: LLM error: %s" (plist-get info :status))
        (let ((source (surveyor-extract-mermaid response)))
          (if (not source)
              (message "surveyor: no Mermaid block in the response")
            (message "surveyor: rendering...")
            (let ((result (surveyor--render source)))
              (cond
               ((plist-get result :file)
                (surveyor--show context source (plist-get result :file)))
               ((< attempt surveyor-max-repair-attempts)
                (message "surveyor: invalid Mermaid, requesting repair (%d/%d)..."
                         (1+ attempt) surveyor-max-repair-attempts)
                (surveyor--request
                 context
                 (concat prompt
                         "\n\nYour previous attempt failed to render:\n```mermaid\n"
                         source "\n```\n\nRenderer error:\n"
                         (plist-get result :error)
                         "\nFix the syntax and reply with only the corrected"
                         " ```mermaid block.")
                 (1+ attempt)))
               (t
                (message "surveyor: giving up after %d attempts: %s"
                         (1+ attempt)
                         (string-trim (or (plist-get result :error) ""))))))))))))

;;;; View buffer

(defvar-local surveyor--source nil
  "Mermaid source of the diagram shown in this view buffer.")

(defvar-local surveyor--context nil
  "Context plist of the diagram shown in this view buffer.")

(defvar-keymap surveyor-view-mode-map
  :parent special-mode-map
  "g" #'surveyor-regenerate
  "s" #'surveyor-show-source
  "w" #'surveyor-copy-source)

(define-derived-mode surveyor-view-mode special-mode "Surveyor"
  "Major mode for viewing surveyor diagrams."
  (setq-local cursor-type nil))

(defun surveyor--display (buffer)
  "Display BUFFER according to the user's display configuration."
  (display-buffer buffer (or surveyor-display-action
                             '(nil (category . surveyor)))))

(defun surveyor--show (context source file)
  "Show the diagram in FILE for CONTEXT, remembering SOURCE."
  (let ((buffer (get-buffer-create (format "*surveyor: %s (%s)*"
                                           (plist-get context :name)
                                           (plist-get context :kind)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'surveyor-view-mode)
        (surveyor-view-mode))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert-image (create-image file 'png nil
                                    :max-width (frame-pixel-width)))
        (insert "\n"))
      (setq surveyor--source source
            surveyor--context context)
      (goto-char (point-min)))
    (surveyor--display buffer)))

(defun surveyor-regenerate ()
  "Regenerate this diagram with a fresh LLM request."
  (interactive nil surveyor-view-mode)
  (unless surveyor--context
    (user-error "No diagram context in this buffer"))
  (surveyor--start surveyor--context))

(defun surveyor-show-source ()
  "Show the Mermaid source of this diagram."
  (interactive nil surveyor-view-mode)
  (unless surveyor--source
    (user-error "No diagram source in this buffer"))
  (let ((buffer (get-buffer-create "*surveyor-source*"))
        (source surveyor--source))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert source))
      (when (fboundp 'mermaid-mode)
        (mermaid-mode)))
    (pop-to-buffer buffer)))

(defun surveyor-copy-source ()
  "Copy the Mermaid source of this diagram to the kill ring."
  (interactive nil surveyor-view-mode)
  (unless surveyor--source
    (user-error "No diagram source in this buffer"))
  (kill-new surveyor--source)
  (message "Copied Mermaid source"))

;;;; Entry points

(defun surveyor--read-kind ()
  "Prompt for a diagram kind."
  (intern (completing-read "Diagram kind: " (mapcar #'car surveyor-kinds)
                           nil t nil nil "flowchart")))

(defun surveyor--start (context)
  "Kick off diagram generation for CONTEXT."
  (surveyor--request context (surveyor--build-prompt context) 0))

;;;###autoload
(defun surveyor-defun (kind)
  "Generate a KIND diagram of the defun at point."
  (interactive (list (surveyor--read-kind)))
  (surveyor--start (plist-put (surveyor--defun-context) :kind kind)))

;;;###autoload
(defun surveyor-file (kind)
  "Generate a KIND diagram of the current file."
  (interactive (list (surveyor--read-kind)))
  (surveyor--start (plist-put (surveyor--file-context) :kind kind)))

(provide 'surveyor)
;;; surveyor.el ends here
