# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Initial MVP: `surveyor-defun` and `surveyor-file` generate diagrams
  (flowchart, sequence, class) of the code at point via gptel.
- Pluggable diagram engines: d2, mermaid, and Graphviz dot (flowchart only).
- Prompt grounding with imenu symbols for file scope.
- Render-validate-repair loop: renderer errors are fed back to the LLM
  for corrected attempts.
- `surveyor-view-mode` buffer with regenerate, show source, and copy source
  commands.
- View buffer built on `image-mode`: fit-to-window display, smooth
  scrolling, and zoom.
- Header line listing the view-buffer keys.
- Window placement via `display-buffer-alist`: action category `surveyor` (Emacs
  30+), buffer name prefix `*surveyor`, or `surveyor-display-action` override.
