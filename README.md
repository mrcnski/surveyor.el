# surveyor.el

Survey your code: LLM-generated diagrams of code, rendered in Emacs!

Surveyor asks your configured LLM (via
[gptel](https://github.com/karthink/gptel)) for a diagram of the code you are
looking at, renders it, feeds renderer errors back to the LLM for automatic
repair, and shows the image in a view buffer.

## Features

- **Scopes:** defun at point or whole file.
- **Kinds of diagrams:** supports flowcharts, sequence diagrams, and class
  diagrams.
- **Abstraction levels:** `code` (uses code symbols) and `logical` (uses plain
  English).
- **Pluggable engines:**
  -  [D2](https://d2lang.com/) (single Go binary, instant renders)
  - [Mermaid](https://mermaid.js.org/) (best LLM fluency)
  - [Graphviz](https://graphviz.org/) (tiny and instant, flowcharts only).
  -  `surveyor-engine` defaults to `auto`: first installed of d2 → mermaid →
     dot.
- **imenu integration:** the LLM labels nodes with names from the imenu symbol
  list.
- **Repair loop:** surveyor attempts to render invalid Mermaid, and the renderer
  error is fed back to the LLM for a corrected attempt.
- **View buffer:** built on `image-mode`.  Hotkeys listed in the header line.

## Requirements

- Emacs 29.1+
- [gptel](https://github.com/karthink/gptel), configured with a backend (see
  below).
- At least one diagram engine:
  - **d2:** `brew install d2` (recommended: fast, no browser)
  - **mermaid:** `npm install -g @mermaid-js/mermaid-cli` for `mmdc`; pulls in
    headless Chromium via puppeteer.
  - **dot:** `brew install graphviz`

## Installation

Not yet on MELPA. From a checkout:

```elisp
(use-package surveyor
  :load-path "path/to/surveyor.el"
  :commands (surveyor surveyor-defun surveyor-file))
```

## Setting up gptel

Surveyor sends its prompts through gptel, so gptel must have a working
backend and API key. If you see:

```
user-error: No ‘gptel-api-key’ found in the auth source
```

gptel is using its default backend (OpenAI/ChatGPT) and looking for a key in
your auth-source (`~/.authinfo`).  Either provide that key, replacing
`sk-your-key-here`:

```
machine api.openai.com login apikey password sk-your-key-here
```

or configure a different backend. Anthropic example:

```elisp
;; Key from ~/.authinfo:
;;   machine api.anthropic.com login apikey password sk-ant-your-key
(setq gptel-model 'claude-opus-4-8
      gptel-backend (gptel-make-anthropic "Claude"
                      :stream t
                      :key #'gptel-api-key-from-auth-source))
```

See the [gptel README](https://github.com/karthink/gptel#setup) for all
supported backends.

## Usage

`M-x surveyor` to open a transient menu with available options.

Some standalone commands are also provided.

## Window placement

Surveyor never hardcodes window placement. Configure it through
`display-buffer-alist`:

```elisp
;; Emacs 30+: match on the action category.
(add-to-list 'display-buffer-alist
             '((category . surveyor)
               (display-buffer-in-side-window)
               (side . right)
               (window-width . 0.45)))

;; Emacs 29: match on the buffer name or major mode instead.
(add-to-list 'display-buffer-alist
             '("^\\*surveyor" display-buffer-in-side-window (side . right)))
```

Or set `surveyor-display-action` to a `display-buffer` action to bypass the
alist entirely.

## Customization

| Variable                       | Default  | Purpose                                        |
|--------------------------------|----------|------------------------------------------------|
| `surveyor-engine`              | `auto`   | Diagram engine: `auto`, `d2`, `mermaid`, `dot` |
| `surveyor-level`               | `code`   | Default abstraction level: `code`, `logical`   |
| `surveyor-d2-command`          | `"d2"`   | D2 executable                                  |
| `surveyor-mmdc-command`        | `"mmdc"` | Mermaid CLI executable                         |
| `surveyor-dot-command`         | `"dot"`  | Graphviz executable                            |
| `surveyor-max-repair-attempts` | `2`      | LLM repair rounds for invalid source           |
| `surveyor-image-scale`         | `2`      | Mermaid render scale (HiDPI crispness)         |
| `surveyor-max-code-chars`      | `100000` | Code truncation limit in prompts               |
| `surveyor-display-action`      | `nil`    | Override `display-buffer` action               |

## Roadmap

- Tree-sitter grounding: prefer `treesit-defun-at-point` / `treesit-defun-name`
  over `bounds-of-thing-at-point` + `add-log-current-defun` in tree-sitter
  modes.
- Directory/project scope (dependency and C4 architecture diagrams)
- Org destination: insert a `#+begin_src` block instead of an image
- Result caching keyed on (code, kind, engine, prompt version)
- PlantUML engine
- Kroki fallback for rendering without a local toolchain

## License

GPL-3.0. See [LICENSE](LICENSE).
