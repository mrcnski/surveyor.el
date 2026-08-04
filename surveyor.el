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

;; Survey your code: LLM-generated diagrams of the defun or file at
;; point,rendered inline in Emacs.
;;
;; Surveyor asks your configured LLM (via gptel) for a diagram of the code you
;; are looking at, validates the result by actually rendering it, feeds renderer
;; errors back to the LLM for automatic repair, and shows the image in a view
;; buffer.
;;
;; Diagrams are produced by a pluggable engine (`surveyor-engine'):
;;
;; - `d2': single Go binary (`brew install d2'), fast native rendering.
;; - `mermaid': needs mermaid-cli (`mmdc'), which drives headless
;;   Chromium; best LLM fluency and pairs with org-babel/ob-mermaid.
;; - `dot': Graphviz, tiny and fast, but flowcharts only.
;;
;; The default `auto' picks the first engine whose binary is installed,
;; in the order d2, mermaid, dot.
;;
;; Entry points: `surveyor-defun' and `surveyor-file'.
;;
;; In the rendered view buffer, the diagram is scaled to fit the window, with
;; the available keys in the header line.

;;; Code:

(require 'cl-lib)
(require 'imenu)
(require 'add-log)
(require 'gptel)

(defgroup surveyor nil
  "LLM-generated diagrams of your code."
  :group 'tools
  :prefix "surveyor-")

(defcustom surveyor-engine 'auto
  "Diagram engine to use.
`auto' picks the first available engine in the order d2, mermaid,
dot.  See `surveyor-engines' for what each engine requires and
which diagram kinds it supports.

Under `auto', mermaid only counts as available when `mmdc' is
actually installed.  Setting this to `mermaid' explicitly also
enables the \"npx -y @mermaid-js/mermaid-cli\" fallback, which
downloads mermaid-cli and headless Chromium (hundreds of MB) into
the npx cache on first use."
  :type '(choice (const :tag "First available (d2, mermaid, dot)" auto)
                 (const d2) (const mermaid) (const dot)))

(defcustom surveyor-d2-command "d2"
  "D2 executable used to validate and render diagrams."
  :type 'string)

(defcustom surveyor-mmdc-command "mmdc"
  "Mermaid CLI executable used to validate and render diagrams.
When it is not found, Surveyor falls back to
\"npx -y @mermaid-js/mermaid-cli\"."
  :type 'string)

(defcustom surveyor-dot-command "dot"
  "Graphviz executable used to validate and render diagrams."
  :type 'string)

(defcustom surveyor-max-repair-attempts 2
  "How many times to feed renderer errors back to the LLM for repair."
  :type 'natnum)

(defcustom surveyor-image-scale 2
  "Scale factor passed to mermaid-cli.
Higher values render crisper images on HiDPI displays.  Only used
by the mermaid engine; d2 and dot output SVG, which scales."
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

;;;; Engines

(defun surveyor--d2-program (&optional _explicit)
  "Return the d2 invocation as a list, or nil if unavailable."
  (when (executable-find surveyor-d2-command)
    (list surveyor-d2-command)))

(defun surveyor--mermaid-program (&optional explicit)
  "Return the mermaid-cli invocation as a list, or nil if unavailable.
The npx fallback downloads mermaid-cli and headless Chromium (hundreds
of MB) into the npx cache on first use, so it is only offered when
EXPLICIT is non-nil -- when the user set `surveyor-engine' to `mermaid'
rather than relying on `auto' detection."
  (cond
   ((executable-find surveyor-mmdc-command)
    (list surveyor-mmdc-command))
   ((and explicit (executable-find "npx"))
    (list "npx" "-y" "@mermaid-js/mermaid-cli"))))

(defun surveyor--dot-program (&optional _explicit)
  "Return the Graphviz dot invocation as a list, or nil if unavailable."
  (when (executable-find surveyor-dot-command)
    (list surveyor-dot-command)))

(defun surveyor--d2-render-args (in out)
  "D2 command-line arguments to render IN to OUT."
  (list in out))

(defun surveyor--mermaid-render-args (in out)
  "Mermaid-cli command-line arguments to render IN to OUT."
  (list "-i" in "-o" out
        "-s" (number-to-string surveyor-image-scale)
        "-b" "white"))

(defun surveyor--dot-render-args (in out)
  "Graphviz command-line arguments to render IN to OUT."
  (list "-Tsvg" "-o" out in))

(defconst surveyor-engines
  '((d2
     :fence "d2" :in-ext ".d2" :out-ext ".svg"
     :program surveyor--d2-program
     :render-args surveyor--d2-render-args
     :bare-re nil
     :syntax "Use plain D2: `name -> name: label' connections and `shape:'
attributes.  Quote names containing spaces or dots."
     :kinds
     ((flowchart . "Draw the control flow: one node per step, `->' edges
for transitions, `shape: diamond' nodes for branch decisions with edge
labels for the outcomes.  Include loops, early returns and error paths;
collapse straight-line statements into single nodes.")
      (sequence . "Draw the interactions as a sequence diagram: a
top-level container with `shape: sequence_diagram', whose participants
are the functions, objects or services involved, with the calls between
them as messages in the order they happen.")
      (class . "Draw the structure: one `shape: class' node per type,
class or module, listing key fields and methods, with edges for the
relationships between them (inheritance, composition, use).")))
    (mermaid
     :fence "mermaid" :in-ext ".mmd" :out-ext ".png"
     :program surveyor--mermaid-program
     :render-args surveyor--mermaid-render-args
     :bare-re "\\(?:flowchart\\|graph\\|sequenceDiagram\\|classDiagram\\|stateDiagram\\|erDiagram\\)"
     :syntax "Do not use HTML in labels."
     :kinds
     ((flowchart . "Draw a flowchart (`flowchart TD') of the control
flow: branches, loops, early returns and error paths.  Collapse
straight-line statements into single nodes.")
      (sequence . "Draw a `sequenceDiagram' of the interactions: the
participants are the functions, objects or services involved; the
messages are the calls between them, in the order they happen.")
      (class . "Draw a `classDiagram' of the structure: the types,
classes or modules with their key fields and methods, and the
relationships between them (inheritance, composition, use).")))
    (dot
     :fence "dot" :in-ext ".gv" :out-ext ".svg"
     :program surveyor--dot-program
     :render-args surveyor--dot-render-args
     :bare-re "\\(?:strict[ \t\n]+\\)?\\(?:di\\)?graph\\_>"
     :syntax "Output Graphviz DOT: a single `digraph' with `label='
attributes; use `shape=diamond' for branch decisions."
     :kinds
     ((flowchart . "Draw the control flow as a digraph: one node per
step, diamond nodes for branch decisions with labeled outgoing edges.
Include loops, early returns and error paths; collapse straight-line
statements into single nodes."))))
  "Alist of engine name to engine definition plist.
Keys: :fence (code-fence language tag), :in-ext / :out-ext (temp file
extensions), :program (function of one argument EXPLICIT -- non-nil when
the user pinned this engine in `surveyor-engine' -- returning the
command as a list, or nil when unavailable), :render-args (function from
input and output file to
argument list), :bare-re (regexp matching an unfenced response's leading
declaration, or nil), :syntax (engine syntax guidance for the LLM), and
:kinds (alist of diagram kind to LLM instruction).")

(defconst surveyor--engine-order '(d2 mermaid dot)
  "Order in which `auto' tries engines.")

(defun surveyor--resolve-engine ()
  "Return (NAME . PLIST) for the first available configured engine.
Signal a `user-error' when no engine's program can be found."
  (let ((candidates (if (eq surveyor-engine 'auto)
                        surveyor--engine-order
                      (list surveyor-engine))))
    (or (cl-loop for name in candidates
                 for plist = (alist-get name surveyor-engines)
                 when (and plist (funcall (plist-get plist :program)
                                          (eq surveyor-engine name)))
                 return (cons name plist))
        (user-error
         "No diagram engine available%s; install d2, mermaid-cli, or graphviz"
         (if (eq surveyor-engine 'auto)
             ""
           (format " (`surveyor-engine' is %s)" surveyor-engine))))))

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

(defun surveyor--system-prompt (engine)
  "Build the system prompt for ENGINE's definition plist."
  (format "You generate diagrams from source code.
Reply with exactly one fenced code block: ```%s ... ```
No prose before or after it.
Only include nodes for things that exist in the provided code or symbol
list, and use their real names as labels.
Keep the diagram readable: at most about 25 nodes.
%s"
          (plist-get engine :fence)
          (plist-get engine :syntax)))

(defun surveyor--build-prompt (context engine)
  "Build the LLM prompt string for CONTEXT using ENGINE's plist."
  (let ((kind (plist-get context :kind)))
    (concat
     (format "Diagram kind: %s.  %s\n\n" kind
             (alist-get kind (plist-get engine :kinds)))
     (when-let* ((symbols (plist-get context :symbols)))
       (format "Definitions in this file (ground truth, from imenu):\n%s\n\n"
               (mapconcat (lambda (s) (concat "- " s)) symbols "\n")))
     (format "Language: %s\n\nSource:\n```\n%s\n```\n"
             (plist-get context :mode)
             (surveyor--clip (plist-get context :code))))))

;;;; Source extraction and rendering

(defun surveyor-extract-source (response fence &optional bare-re)
  "Extract diagram source from LLM RESPONSE, or return nil.
Prefer a code block fenced with FENCE, then any fenced block, then --
when BARE-RE is non-nil -- a bare response whose first expression
matches it."
  (cond
   ((string-match (format "```%s[ \t]*\n\\(\\(?:.\\|\n\\)*?\\)\n?```"
                          (regexp-quote fence))
                  response)
    (string-trim (match-string 1 response)))
   ((string-match "```[a-z0-9]*[ \t]*\n\\(\\(?:.\\|\n\\)*?\\)\n?```" response)
    (string-trim (match-string 1 response)))
   ((and bare-re
         (string-match (concat "\\`[ \t\n]*\\(" bare-re "\\(?:.\\|\n\\)*\\)\\'")
                       response))
    (string-trim (match-string 1 response)))))

(defun surveyor--render (engine-name source)
  "Render diagram SOURCE with engine ENGINE-NAME.
Return (:file FILE) on success or (:error STRING) on failure."
  (let* ((engine (alist-get engine-name surveyor-engines))
         (program (funcall (plist-get engine :program)
                           (eq surveyor-engine engine-name))))
    (if (not program)
        (list :error (format "engine %s is not available" engine-name))
      (let ((in (make-temp-file "surveyor-" nil (plist-get engine :in-ext)
                                source))
            (out (make-temp-file "surveyor-" nil (plist-get engine :out-ext))))
        (unwind-protect
            (with-temp-buffer
              (let ((status (apply #'call-process (car program) nil t nil
                                   (append (cdr program)
                                           (funcall (plist-get engine :render-args)
                                                    in out)))))
                (if (and (eql status 0)
                         (> (file-attribute-size (file-attributes out)) 0))
                    (list :file out)
                  (list :error (buffer-string)))))
          (delete-file in))))))

;;;; Request and repair loop

(defun surveyor--request (context prompt attempt)
  "Send PROMPT for CONTEXT to the LLM; ATTEMPT counts repair rounds."
  (let* ((engine-name (plist-get context :engine))
         (engine (alist-get engine-name surveyor-engines)))
    (message "surveyor: asking LLM (%s via %s)..."
             (plist-get context :kind) engine-name)
    (gptel-request prompt
      :system (surveyor--system-prompt engine)
      :callback
      (lambda (response info)
        (if (not (stringp response))
            (message "surveyor: LLM error: %s" (plist-get info :status))
          (let ((source (surveyor-extract-source response
                                                 (plist-get engine :fence)
                                                 (plist-get engine :bare-re))))
            (if (not source)
                (message "surveyor: no diagram source in the response")
              (message "surveyor: rendering...")
              (let ((result (surveyor--render engine-name source)))
                (cond
                 ((plist-get result :file)
                  (surveyor--show context source (plist-get result :file)))
                 ((< attempt surveyor-max-repair-attempts)
                  (message "surveyor: invalid %s, requesting repair (%d/%d)..."
                           engine-name (1+ attempt) surveyor-max-repair-attempts)
                  (surveyor--request
                   context
                   (concat prompt
                           (format "\n\nYour previous attempt failed to render:\n```%s\n%s\n```\n\nRenderer error:\n%s\nFix the syntax and reply with only the corrected ```%s block."
                                   (plist-get engine :fence) source
                                   (plist-get result :error)
                                   (plist-get engine :fence)))
                   (1+ attempt)))
                 (t
                  (message "surveyor: giving up after %d attempts: %s"
                           (1+ attempt)
                           (string-trim (or (plist-get result :error) "")))))))))))))

;;;; View buffer

(defvar-local surveyor--source nil
  "Diagram source shown in this view buffer.")

(defvar-local surveyor--context nil
  "Context plist of the diagram shown in this view buffer.")

(defvar-local surveyor--file nil
  "Rendered image file shown in this view buffer.")

(defvar-local surveyor--zoom 1.0
  "Zoom factor relative to the fit-to-window size.")

(defvar-keymap surveyor-view-mode-map
  :parent special-mode-map
  "g" #'surveyor-regenerate
  "s" #'surveyor-show-source
  "w" #'surveyor-copy-source
  "S" #'surveyor-save-image
  "+" #'surveyor-zoom-in
  "=" #'surveyor-zoom-in
  "-" #'surveyor-zoom-out
  "0" #'surveyor-zoom-reset)

(define-derived-mode surveyor-view-mode special-mode "Surveyor"
  "Major mode for viewing surveyor diagrams."
  (setq-local cursor-type nil)
  (setq-local header-line-format
              (substitute-command-keys
               (concat "\\<surveyor-view-mode-map>"
                       "\\[surveyor-regenerate] regenerate"
                       "  \\[surveyor-show-source] source"
                       "  \\[surveyor-copy-source] copy"
                       "  \\[surveyor-save-image] save"
                       "  \\[surveyor-zoom-in]/\\[surveyor-zoom-out] zoom"
                       "  \\[surveyor-zoom-reset] refit"
                       "  \\[quit-window] quit"))))

(defun surveyor--display (buffer)
  "Display BUFFER according to the user's display configuration.
Return the window showing it."
  (display-buffer buffer (or surveyor-display-action
                             '(nil (category . surveyor)))))

(defun surveyor--fit-scale (native window-width window-height)
  "Return the scale fitting NATIVE (WIDTH . HEIGHT) into the window body.
WINDOW-WIDTH and WINDOW-HEIGHT are in pixels.  Images smaller than
the window are not scaled up."
  (min 1.0
       (/ (float window-width) (max 1 (car native)))
       (/ (float window-height) (max 1 (cdr native)))))

(defun surveyor--image (window)
  "Create the diagram image for WINDOW at the current zoom."
  (let* ((native (image-size (create-image surveyor--file nil nil :scale 1) t))
         (fit (surveyor--fit-scale native
                                   (window-body-width window t)
                                   (window-body-height window t))))
    (create-image surveyor--file nil nil :scale (* fit surveyor--zoom))))

(defun surveyor--refresh (&optional window)
  "Redraw the diagram at the current zoom, fitted to WINDOW."
  (unless surveyor--file
    (user-error "No diagram in this buffer"))
  (let ((window (or window
                    (get-buffer-window (current-buffer))
                    (selected-window)))
        (inhibit-read-only t))
    (erase-buffer)
    (insert-image (surveyor--image window))
    (insert "\n")
    (goto-char (point-min))))

(defun surveyor--show (context source file)
  "Show the diagram in FILE for CONTEXT, remembering SOURCE."
  (let ((buffer (get-buffer-create (format "*surveyor: %s (%s)*"
                                           (plist-get context :name)
                                           (plist-get context :kind)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'surveyor-view-mode)
        (surveyor-view-mode))
      (setq surveyor--source source
            surveyor--context context
            surveyor--file file
            surveyor--zoom 1.0))
    ;; Display first: fit-to-window needs the real window size, which
    ;; `display-buffer-alist' side-window entries and the like decide.
    (let ((window (surveyor--display buffer)))
      (with-current-buffer buffer
        (surveyor--refresh window)))))

(defun surveyor-zoom-in ()
  "Enlarge the diagram."
  (interactive nil surveyor-view-mode)
  (setq surveyor--zoom (* surveyor--zoom 1.25))
  (surveyor--refresh))

(defun surveyor-zoom-out ()
  "Shrink the diagram."
  (interactive nil surveyor-view-mode)
  (setq surveyor--zoom (/ surveyor--zoom 1.25))
  (surveyor--refresh))

(defun surveyor-zoom-reset ()
  "Fit the diagram to the window."
  (interactive nil surveyor-view-mode)
  (setq surveyor--zoom 1.0)
  (surveyor--refresh))

(defun surveyor-regenerate ()
  "Regenerate this diagram with a fresh LLM request."
  (interactive nil surveyor-view-mode)
  (unless surveyor--context
    (user-error "No diagram context in this buffer"))
  (surveyor--start surveyor--context))

(defun surveyor-show-source ()
  "Show the source of this diagram."
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
  "Copy the source of this diagram to the kill ring."
  (interactive nil surveyor-view-mode)
  (unless surveyor--source
    (user-error "No diagram source in this buffer"))
  (kill-new surveyor--source)
  (message "Copied diagram source"))

(defun surveyor--save-default-name ()
  "Default file name for saving this buffer's diagram image."
  (format "%s-%s%s"
          (replace-regexp-in-string "[ /]" "-"
                                    (plist-get surveyor--context :name))
          (plist-get surveyor--context :kind)
          (file-name-extension surveyor--file t)))

(defun surveyor-save-image (file)
  "Save the rendered diagram image to FILE."
  (interactive
   (progn
     (unless surveyor--file
       (user-error "No diagram in this buffer"))
     (list (read-file-name "Save diagram to: " nil nil nil
                           (surveyor--save-default-name))))
   surveyor-view-mode)
  (copy-file surveyor--file file 1)
  (message "Saved diagram to %s" file))

;;;; Entry points

(defun surveyor--read-kind (engine)
  "Prompt for a diagram kind supported by ENGINE's plist."
  (let ((kinds (mapcar #'car (plist-get engine :kinds))))
    (if (cdr kinds)
        (intern (completing-read "Diagram kind: " kinds nil t nil nil
                                 (symbol-name (car kinds))))
      (car kinds))))

(defun surveyor--start (context)
  "Kick off diagram generation for CONTEXT."
  (let ((engine (alist-get (plist-get context :engine) surveyor-engines)))
    (surveyor--request context (surveyor--build-prompt context engine) 0)))

(defun surveyor--run (context-fn)
  "Resolve engine and kind, then generate from CONTEXT-FN's context."
  (pcase-let* ((`(,engine-name . ,engine) (surveyor--resolve-engine))
               (kind (surveyor--read-kind engine)))
    (surveyor--start (append (list :kind kind :engine engine-name)
                             (funcall context-fn)))))

;;;###autoload
(defun surveyor-defun ()
  "Generate a diagram of the defun at point."
  (interactive)
  (surveyor--run #'surveyor--defun-context))

;;;###autoload
(defun surveyor-file ()
  "Generate a diagram of the current file."
  (interactive)
  (surveyor--run #'surveyor--file-context))

(provide 'surveyor)
;;; surveyor.el ends here
