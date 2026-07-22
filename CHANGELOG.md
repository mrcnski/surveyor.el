# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Initial MVP: `surveyor-defun` and `surveyor-file` generate diagrams
  (flowchart, sequence, class) of the code at point via gptel.
- Pluggable diagram engines: d2, mermaid (via `mmdc` or
  `npx -y @mermaid-js/mermaid-cli`), and Graphviz dot (flowchart only).
  `surveyor-engine` defaults to `auto` — first installed of d2,
  mermaid, dot.
- Prompt grounding with imenu symbols for file scope.
- Render-validate-repair loop: renderer errors are fed back to the LLM
  for corrected attempts.
- `surveyor-view-mode` buffer with regenerate (`g`), show source (`s`),
  and copy source (`w`) commands.
- Window placement via `display-buffer-alist` — action category
  `surveyor` (Emacs 30+), buffer name prefix `*surveyor`, or
  `surveyor-display-action` override.
- ERT tests for Mermaid extraction, prompt building, and truncation.
