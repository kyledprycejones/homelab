# Patch queue
This folder stores patch diffs submitted by the orchestrator for quick replay or inspection.

- `S1-001-RUN-ENG.diff` is a recent engineer patch that the executor can apply when the AI workflow detects drift.

Populate this directory with similar small patches tied to backlog tickets so the executor can fetch them without remastering the entire repo.
