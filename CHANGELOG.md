# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- imenu's `*Rescan*` menu entry is no longer sent to the LLM as one of the
  file's definitions.

## [0.1.0] - 2026-08-17

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
- `surveyor-open-externally` (`E`): open the rendered image in the
  system's default application.
- `surveyor`: transient menu over diagram kind, level, engine, and scope.
- Abstraction levels: `code` (uses code symbols) and `logical` (uses plain
  English).
- `surveyor-kind`: user option for the default diagram kind.
