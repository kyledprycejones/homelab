# Patch queue
This folder stores patch diffs submitted by the orchestrator for quick replay or inspection.

- v7.2 uses planner-generated recovery tasks instead of persona-authored patches. Any legacy diffs in this folder should be treated as manual artifacts, not automated inputs.

Populate this directory only when a human explicitly stages a patch for executor application. Escalations otherwise flow through planner-generated tasks (RECONCILE → DELETE/RESET → APPLY → VALIDATE).
