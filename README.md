# surveyor.el

Survey your code: LLM-generated diagrams of the defun or file at point,
rendered inline in Emacs.

Surveyor asks your configured LLM (via [gptel](https://github.com/karthink/gptel))
for a diagram of the code you are looking at, validates the result by
actually rendering it, feeds renderer errors back to the LLM for automatic
repair, and shows the image in a view buffer.

**Status: early WIP.**

## Features

- **Scopes:** defun at point (`surveyor-defun`) or whole file (`surveyor-file`).
- **Kinds:** control-flow `flowchart`, `sequence` diagram, `class` diagram.
- **Pluggable engines:** [D2](https://d2lang.com/) (single Go binary, instant
  renders), [Mermaid](https://mermaid.js.org/) (best LLM fluency, pairs with
  ob-mermaid, but its CLI drives headless Chromium), or
  [Graphviz](https://graphviz.org/) (tiny and instant; flowcharts only).
  `surveyor-engine` defaults to `auto`: first installed of d2 → mermaid → dot.
- **Grounded prompts:** file-scope prompts include the imenu symbol list as
  ground truth, so the LLM labels nodes with names that actually exist.
- **Repair loop:** invalid Mermaid is rendered anyway, and the renderer error
  is fed back to the LLM for a corrected attempt
  (`surveyor-max-repair-attempts`).
- **View buffer:** `g` regenerate, `s` show Mermaid source, `w` copy source,
  `q` quit.

## Requirements

- Emacs 29.1+
- [gptel](https://github.com/karthink/gptel), configured with a backend
- At least one diagram engine:
  - **d2** — `brew install d2` (recommended: fast, no browser)
  - **mermaid** — `npm install -g @mermaid-js/mermaid-cli` for `mmdc`
    (falls back to `npx -y @mermaid-js/mermaid-cli`); pulls in headless
    Chromium via puppeteer
  - **dot** — `brew install graphviz`

## Installation

Not yet on MELPA. From a checkout:

```elisp
(use-package surveyor
  :load-path "path/to/surveyor.el"
  :commands (surveyor-defun surveyor-file))
```

## Usage

`M-x surveyor-defun` or `M-x surveyor-file`, pick a diagram kind, wait for
the render. The LLM request is asynchronous; the render step is synchronous
and typically takes 1–3 seconds.

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

| Variable | Default | Purpose |
|---|---|---|
| `surveyor-engine` | `auto` | Diagram engine: `auto`, `d2`, `mermaid`, `dot` |
| `surveyor-d2-command` | `"d2"` | D2 executable |
| `surveyor-mmdc-command` | `"mmdc"` | Mermaid CLI executable |
| `surveyor-dot-command` | `"dot"` | Graphviz executable |
| `surveyor-max-repair-attempts` | `2` | LLM repair rounds for invalid source |
| `surveyor-image-scale` | `2` | Mermaid render scale (HiDPI crispness) |
| `surveyor-max-code-chars` | `100000` | Code truncation limit in prompts |
| `surveyor-display-action` | `nil` | Override `display-buffer` action |

## Roadmap

- Transient entry menu (scope × kind × destination)
- Directory/project scope (dependency and C4 architecture diagrams)
- Org destination: insert a `#+begin_src` block instead of an image
- Result caching keyed on (code, kind, engine, prompt version)
- PlantUML engine
- Kroki fallback for rendering without a local toolchain

## License

GPL-3.0. See [LICENSE](LICENSE).
