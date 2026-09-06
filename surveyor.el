;;; surveyor.el --- Survey your code with LLM-generated diagrams -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Marcin Swieczkowski

;; Author: Marcin Swieczkowski <marcin@realemail.net>
;; Assisted-by: Claude:claude-fable-5
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (gptel "0.9.0") (transient "0.4.0"))
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

;; Survey your code: LLM-generated diagrams of code, rendered inline in Emacs.
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
;; Entry points: `surveyor' (or the standalone commands).
;;
;; The rendered diagram is shown in an `image-mode' buffer (fit to window,
;; smooth scrolling, zoom) with surveyor keys on top, listed in the header
;; line.

;;; Code:

(require 'cl-lib)
(require 'imenu)
(require 'add-log)
(require 'image-mode)
(require 'transient)
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

(defcustom surveyor-kind 'flowchart
  "Diagram kind offered by default.
The menu starts on this kind and prompts offer it as the answer.  An
engine that cannot draw it falls back to the first kind it supports;
see `surveyor-engines' for what each engine can draw."
  :type '(choice (const :tag "Control flow" flowchart)
                 (const :tag "Message sequence" sequence)
                 (const :tag "Class relationships" class)))

(defcustom surveyor-level 'code
  "Abstraction level offered by default.
The menu starts on this level and commands fall back to it.  See
`surveyor-levels' for a description of each level."
  :type '(choice (const :tag "Control flow as written" code)
                 (const :tag "Logical steps only" logical)))

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

;;;; Levels

(defconst surveyor-levels
  '((code
     :nodes 25
     :naming "Only include nodes for things that exist in the provided code or
symbol list, and use their real names as labels."
     :prompt nil)
    (logical
     :nodes 12
     :naming "Label nodes with short descriptive phrases saying what happens,
in the vocabulary of the problem domain rather than raw identifiers.  Stay
faithful to what the code actually does: do not invent steps it does not
perform."
     :prompt "Diagram this at a high level, for a reader who wants to
understand what the code accomplishes rather than how it is written.  Group
runs of statements into meaningful steps named after what they achieve, and
omit mechanical detail -- argument validation, logging, error plumbing,
accessors, type conversions -- unless it is essential to the logic.  This
overrides the node granularity described above; keep following its diagram
syntax."))
  "Alist of abstraction level to definition plist.
`code' draws the control flow as written; `logical' draws the reasoning
behind it for a human reader.

Keys: :nodes (node budget for the system prompt), :naming (how to label
nodes), and :prompt (extra instruction added to the request, or nil).")

(defun surveyor--level (name)
  "Return the definition plist for level NAME, defaulting when nil."
  (alist-get (or name surveyor-level) surveyor-levels))

(defun surveyor--kind-label (context)
  "Display label for CONTEXT's diagram, qualified by level when not the default."
  (let ((kind (plist-get context :kind))
        (level (plist-get context :level)))
    (if (memq level (list nil surveyor-level))
        (format "%s" kind)
      (format "%s %s" level kind))))

;;;; Context collection

(defun surveyor--imenu-symbols ()
  "Return a flat list of symbol names from imenu, or nil."
  ;; Return nil when the major mode has no imenu support. Even with its NOERROR
  ;; argument, `imenu--make-index-alist' signals `imenu-unavailable'.
  (let ((index (condition-case nil
                   (imenu--make-index-alist t)
                 (imenu-unavailable nil)))
        names)
    (cl-labels ((walk (items)
                  (dolist (item items)
                    (cond ((imenu--subalist-p item) (walk (cdr item)))
                          ((stringp (car item)) (push (car item) names))))))
      (walk index))
    (nreverse names)))

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

(defun surveyor--system-prompt (engine level)
  "Build the system prompt for ENGINE's and LEVEL's definition plists.
The node budget and the node-naming rule both come from LEVEL."
  (format "You generate diagrams from source code.
Reply with exactly one fenced code block: ```%s ... ```
No prose before or after it.
%s
Keep the diagram readable: at most about %d nodes.
%s"
          (plist-get engine :fence)
          (plist-get level :naming)
          (plist-get level :nodes)
          (plist-get engine :syntax)))

(defun surveyor--build-prompt (context engine)
  "Build the LLM prompt string for CONTEXT using ENGINE's plist."
  (let ((kind (plist-get context :kind))
        (level (surveyor--level (plist-get context :level))))
    (concat
     (format "Diagram kind: %s.  %s\n\n" kind
             (alist-get kind (plist-get engine :kinds)))
     (when-let* ((extra (plist-get level :prompt)))
       (concat extra "\n\n"))
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
             (surveyor--kind-label context) engine-name)
    (gptel-request prompt
      :system (surveyor--system-prompt
               engine (surveyor--level (plist-get context :level)))
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

(defvar-keymap surveyor-diagram-mode-map
  "g" #'surveyor-regenerate
  "s" #'surveyor-show-source
  "w" #'surveyor-copy-source
  "S" #'surveyor-save-image
  "E" #'surveyor-open-externally
  "+" #'surveyor-zoom-in
  "=" #'surveyor-zoom-in
  "-" #'surveyor-zoom-out
  "0" #'image-transform-fit-to-window
  "q" #'quit-window
  ;; `image-mode' remaps the keyboard scroll commands to clamped,
  ;; pixel-precise variants, but wheel events go through `mwheel-scroll'
  ;; and plain `scroll-up'/`scroll-down', which jump past the image.
  "<wheel-down>" #'surveyor-wheel-down
  "<wheel-up>" #'surveyor-wheel-up
  "<wheel-right>" #'surveyor-wheel-right
  "<wheel-left>" #'surveyor-wheel-left)

(define-minor-mode surveyor-diagram-mode
  "Surveyor commands on top of `image-mode' in diagram view buffers.
The heavy lifting -- fitting the image to the window, pixel-precise
scrolling, zooming -- is `image-mode's.
\\{surveyor-diagram-mode-map}"
  :interactive nil
  (when surveyor-diagram-mode
    (setq header-line-format
          (substitute-command-keys
           (concat "\\<surveyor-diagram-mode-map>"
                   "\\[surveyor-regenerate] regenerate"
                   "  \\[surveyor-show-source] source"
                   "  \\[surveyor-copy-source] copy"
                   "  \\[surveyor-save-image] save"
                   "  \\[surveyor-open-externally] open"
                   "  \\[surveyor-zoom-in]/\\[surveyor-zoom-out] zoom"
                   "  \\[image-transform-fit-to-window] refit"
                   "  \\[quit-window] quit")))))

(defun surveyor-zoom-in ()
  "Enlarge the diagram.
`image-increase-size' looks the image up at point (deferred to a
timer), but point in an `image-mode' data buffer is not reliably on
the image text; anchor the lookup at `point-min', where the image's
display property starts.  Moving point there also keeps the
transient repeat map (`+ + ...') working."
  (interactive nil surveyor-diagram-mode)
  (goto-char (point-min))
  (image-increase-size nil (point-min-marker)))

(defun surveyor-zoom-out ()
  "Shrink the diagram."
  (interactive nil surveyor-diagram-mode)
  (goto-char (point-min))
  (image-decrease-size nil (point-min-marker)))

(defun surveyor-wheel-down ()
  "Scroll the diagram a step down."
  (interactive nil surveyor-diagram-mode)
  (image-scroll-up 2))

(defun surveyor-wheel-up ()
  "Scroll the diagram a step up."
  (interactive nil surveyor-diagram-mode)
  (image-scroll-down 2))

(defun surveyor-wheel-right ()
  "Scroll the diagram a step to the right."
  (interactive nil surveyor-diagram-mode)
  (image-forward-hscroll 2))

(defun surveyor-wheel-left ()
  "Scroll the diagram a step to the left."
  (interactive nil surveyor-diagram-mode)
  (image-backward-hscroll 2))

(defun surveyor--display (buffer)
  "Display BUFFER according to the user's display configuration.
Return the window showing it."
  (display-buffer buffer (or surveyor-display-action
                             '(nil (category . surveyor)))))

(defun surveyor--show (context source file)
  "Show the diagram in FILE for CONTEXT, remembering SOURCE."
  (let ((buffer (get-buffer-create (format "*surveyor: %s (%s)*"
                                           (plist-get context :name)
                                           (surveyor--kind-label context)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (buffer-undo-list t))
        (erase-buffer)
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file)))
    ;; Display before enabling `image-mode', which fits the image to
    ;; the window the buffer is shown in.
    (surveyor--display buffer)
    (with-current-buffer buffer
      (image-mode)
      (surveyor-diagram-mode 1)
      (goto-char (point-min))
      ;; After `image-mode': changing the major mode kills buffer-locals.
      (setq surveyor--source source
            surveyor--context context
            surveyor--file file))))

(defun surveyor-regenerate ()
  "Regenerate this diagram with a fresh LLM request."
  (interactive nil surveyor-diagram-mode)
  (unless surveyor--context
    (user-error "No diagram context in this buffer"))
  (surveyor--start surveyor--context))

(defun surveyor-show-source ()
  "Show the source of this diagram."
  (interactive nil surveyor-diagram-mode)
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
  (interactive nil surveyor-diagram-mode)
  (unless surveyor--source
    (user-error "No diagram source in this buffer"))
  (kill-new surveyor--source)
  (message "Copied diagram source"))

(declare-function w32-shell-execute "w32fns.c")

(defun surveyor-open-externally ()
  "Open the rendered diagram with the system's default application.
Like `dired-do-open' (bound to \\`E' in Dired), but without Emacs
30's `shell-command-guess-open'."
  (interactive nil surveyor-diagram-mode)
  (unless surveyor--file
    (user-error "No diagram in this buffer"))
  (pcase system-type
    ('darwin (call-process "open" nil 0 nil surveyor--file))
    ('windows-nt (w32-shell-execute "open" surveyor--file))
    ((guard (executable-find "xdg-open"))
     (call-process "xdg-open" nil 0 nil surveyor--file))
    (_ (browse-url-of-file surveyor--file))))

(defun surveyor--save-default-name ()
  "Default file name for saving this buffer's diagram image."
  (format "%s-%s%s"
          (replace-regexp-in-string "[ /]" "-"
                                    (plist-get surveyor--context :name))
          (replace-regexp-in-string " " "-"
                                    (surveyor--kind-label surveyor--context))
          (file-name-extension surveyor--file t)))

(defun surveyor-save-image (file)
  "Save the rendered diagram image to FILE."
  (interactive
   (progn
     (unless surveyor--file
       (user-error "No diagram in this buffer"))
     (list (read-file-name "Save diagram to: " nil nil nil
                           (surveyor--save-default-name))))
   surveyor-diagram-mode)
  (copy-file surveyor--file file 1)
  (message "Saved diagram to %s" file))

;;;; Entry points

(defun surveyor--read-kind (engine)
  "Prompt for a diagram kind supported by ENGINE's plist.
Offer `surveyor-kind' as the answer, or ENGINE's first kind when
ENGINE cannot draw it."
  (let ((kinds (mapcar #'car (plist-get engine :kinds))))
    (if (cdr kinds)
        (intern (completing-read
                 "Diagram kind: " kinds nil t nil nil
                 (symbol-name (if (memq surveyor-kind kinds)
                                  surveyor-kind
                                (car kinds)))))
      (car kinds))))

(defun surveyor--start (context)
  "Kick off diagram generation for CONTEXT."
  (let ((engine (alist-get (plist-get context :engine) surveyor-engines)))
    (surveyor--request context (surveyor--build-prompt context engine) 0)))

(defun surveyor--run (context-fn &optional kind engine-name level)
  "Resolve engine and kind, then generate from CONTEXT-FN's context.
When ENGINE-NAME is non-nil it is used as `surveyor-engine'.  When KIND
is nil it is read interactively.  LEVEL defaults to `surveyor-level'."
  (let ((surveyor-engine (or engine-name surveyor-engine)))
    (pcase-let* ((`(,resolved . ,engine) (surveyor--resolve-engine))
                 (kind (or kind (surveyor--read-kind engine)))
                 (level (or level surveyor-level)))
      (unless (alist-get kind (plist-get engine :kinds))
        (user-error "Engine %s only supports %s diagrams" resolved
                    (mapconcat (lambda (k) (symbol-name (car k)))
                               (plist-get engine :kinds) ", ")))
      (unless (surveyor--level level)
        (user-error "Unknown diagram level: %s" level))
      (surveyor--start (append (list :kind kind :engine resolved :level level)
                               (funcall context-fn))))))

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

;;;; Transient menu

(defun surveyor--all-kinds ()
  "Return the diagram kind names supported by any engine."
  (let (kinds)
    (dolist (entry surveyor-engines (nreverse kinds))
      (dolist (kind (plist-get (cdr entry) :kinds))
        (let ((name (symbol-name (car kind))))
          (unless (member name kinds)
            (push name kinds)))))))

(defun surveyor--engine-names ()
  "Return the engine choices for the menu, including \"auto\"."
  (cons "auto" (mapcar (lambda (entry) (symbol-name (car entry)))
                       surveyor-engines)))

(defun surveyor--level-names ()
  "Return the abstraction level choices for the menu."
  (mapcar (lambda (entry) (symbol-name (car entry))) surveyor-levels))

(defclass surveyor--choice (transient-option) ()
  "Menu option that always holds one of a fixed set of choices.")

(cl-defmethod transient-infix-read ((obj surveyor--choice))
  "Choose one of OBJ's choices, keeping the current value by default.
The default method unsets an already-set option when its key is
pressed again, and clears it on empty input.  Neither makes sense for
options the generate commands always need, so re-read instead, with
the current value as the completion default."
  (let ((choices (oref obj choices)))
    (when (functionp choices)
      (setq choices (funcall choices)))
    (completing-read (transient-prompt obj) choices nil t nil nil
                     (or (oref obj value) (car choices)))))

(defun surveyor--menu-defaults ()
  "Return one starting argument for every menu option.
Kind, level, and engine come from the like-named user options, so the
menu always displays exactly what a generate command will use."
  (list (format "--kind=%s" surveyor-kind)
        (format "--level=%s" surveyor-level)
        (format "--engine=%s" surveyor-engine)))

(defun surveyor--menu-arg (args key)
  "Return the value of the KEY= argument in ARGS, or nil."
  (when-let* ((match (seq-find (lambda (arg) (string-prefix-p key arg)) args)))
    (substring match (length key))))

(defun surveyor--menu-run (context-fn)
  "Generate from CONTEXT-FN with the options chosen in the menu."
  (let ((args (transient-args 'surveyor)))
    ;; `auto' stays `auto': it must auto-detect even when
    ;; `surveyor-engine' pins a concrete engine.
    (surveyor--run context-fn
                   (intern (surveyor--menu-arg args "--kind="))
                   (intern (surveyor--menu-arg args "--engine="))
                   (intern (surveyor--menu-arg args "--level=")))))

(defun surveyor-generate-defun ()
  "Generate the diagram selected in the menu for the defun at point."
  (interactive)
  (surveyor--menu-run #'surveyor--defun-context))

(defun surveyor-generate-file ()
  "Generate the diagram selected in the menu for the current file."
  (interactive)
  (surveyor--menu-run #'surveyor--file-context))

;;;###autoload (autoload 'surveyor "surveyor" nil t)
(transient-define-prefix surveyor ()
  "Generate an LLM diagram of the code at hand."
  ;; The default-value slot. Unlike `:init-value' it yields to values
  ;; set in-session or saved with `transient-save'.
  :value #'surveyor--menu-defaults
  ["Options"
   ("k" "Diagram kind" "--kind=" :class surveyor--choice
    :prompt "Diagram kind: " :choices surveyor--all-kinds)
   ("l" "Level (code flow vs. logical flow)" "--level=" :class surveyor--choice
    :prompt "Abstraction level: " :choices surveyor--level-names)
   ("e" "Engine" "--engine=" :class surveyor--choice
    :prompt "Engine: " :choices surveyor--engine-names)]
  ["Generate"
   ("d" "Defun at point" surveyor-generate-defun)
   ("f" "Whole file" surveyor-generate-file)])

(provide 'surveyor)
;;; surveyor.el ends here
