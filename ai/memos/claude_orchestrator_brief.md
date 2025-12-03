	📄 Memo to Claude – Funoffshore Orchestrator & Homelab

Audience: Claude Code / Cursor AI
Scope: Stage 0 (Orchestrator) and Stage 1 (Homelab).
Note: Later stages (AI Studio, multi-biz engine) are paused and out of scope for now.

⸻

1. High-Level Goal

This repository is my Funoffshore homelab plus an AI orchestrator.
	•	Stage 0 – Orchestrator:
An AI-driven control loop that takes human intent and constructs/maintains the homelab by coordinating multiple personas (Executor, Engineer, Planner) plus human review when needed.
	•	Stage 1 – Homelab:
The actual infrastructure: Proxmox, Talos/Kubernetes, GitOps, storage, monitoring, etc.
Stage 1 should eventually be constructible and maintainable from human prompts, with the orchestrator doing most of the mechanical work.

For now, focus on:

Make Stage 0 stable and trustworthy, so it can reliably build and maintain Stage 1 via Codex CLI and SSH to the N100.

⸻

2. Key Components & Layout

Important directories:
	•	ai/orchestrator/
Core orchestrator logic, state machine helpers, persona handlers.
	•	ai/scripts/
Orchestrator entrypoints (orchestrator_loop.sh), harness scripts, support utilities.
	•	ai/state/
JSON state for the orchestrator:
	•	status.json – global status per task
	•	current_task.json – what’s running now
	•	metrics.json – retries, failure counts
	•	last_error.json – last classified error
	•	flags like stage1_complete.json, stage2_ready.json (future)
	•	ai/logs/
Logs for orchestrator runs, personas, executor, and overall runs.
	•	ai/backlog.yaml
Primary backlog of tasks. Each task has:
	•	task_id
	•	type (run, patch, etc.)
	•	persona (executor, engineer, planner)
	•	target (script/path)
	•	metadata (stage, cluster, etc.)
	•	status (pending → running → etc.)
	•	infrastructure/, cluster/, config/
Actual homelab infra (Proxmox/Talos/K8s/etc.).
Stage 1 lives here. Orchestrator interacts with these through tasks.

The orchestrator is Stage 0; the rest of the repo is Stage 1 and beyond.

Current Repository Structure (Authoritative) - important

The repository ALREADY matches the following structure. 
Treat this as a description, not as a task.

If there is any mismatch between this diagram and the actual filesystem, 
ASSUME THE FILESYSTEM IS CORRECT and the diagram is out of date.

NEVER create, delete, or move top-level directories (ai/, cluster/, config/, docs/, infrastructure/) to "make it match" the diagram unless I explicitly tell you to.

Top level: README.md, CONTRIBUTING.md, codex_loop.sh, plus key directories ai/, cluster/, config/, docs/, and infrastructure/.
ai/: contains workflows, agents, scripts, orchestrator, logs, backlog.yaml, and both README.md and .ai subdirectories for tasks/memos.
cluster/: split into talos/ and kubernetes/ configurations.
config/: stores clusters/ and env/ definitions.
docs/: includes several markdowns (architecture.md, stage1_talos_overview.md, README.md, repo-contract.md, bootstrap-stages.md).
Hidden dirs: .venv/ (Python virtualenv with bin/lib structure), .git/, .vscode/settings.json, .sops.yaml, plus .DS_Store.
infrastructure/: holds synology/ and proxmox/ branches of infra configs. proxmox holds the cluster bootstrap

⸻

3. Persona Model & RACI

We have three main AI personas plus the human:

3.1 Executor (Hands / Runner)
	•	Role: Executes commands and scripts, primarily via SSH on the N100, and performs small/local fixes.
	•	Responsibilities:
	•	Run scripts like infrastructure/proxmox/cluster_bootstrap.sh via Codex CLI and SSH.
	•	Apply small, local code or config fixes (e.g., a one-line bash fix, a minor YAML tweak).
	•	Read logs, summarize errors, and push error context into ai/state/last_error.json and logs.
	•	Authority:
	•	Can run commands over SSH on the N100, but must NOT reboot the N100.
	•	Should NOT make broad, multi-file refactors or heavy structural changes.
	•	Should NOT run destructive or cluster-wide commands unless explicitly part of a task.
	•	When to escalate:
After a small number of retries (e.g., 2–3 attempts) on the same task with similar errors, Executor escalates upward.

3.2 Engineer (Repo Surgeon / Fixer)
	•	Role: Primary implementer who modifies code/config across the repo.
	•	Responsibilities:
	•	Analyze last_error.json, logs, and failing tasks.
	•	Modify any necessary file across the repo to fix issues (not just orchestrator).
	•	Create patches for code, scripts, or configs.
	•	Coordinate with Planner to break work into manageable chunks.
	•	Authority:
	•	May touch any part of the repo when necessary (orchestrator, infra, cluster, etc.).
	•	Should still keep changes surgical and small, not giant rewrites.
	•	When to escalate:
After a few failed attempts or when the problem feels too big/vague → escalate to Planner for a higher-level decomposition.

3.3 Planner (Architect / Strategist)
	•	Role: High-level planner and chunker of work.
	•	Responsibilities:
	•	Take a complex or recurring failure and:
	•	Analyze root cause at an architectural / system level.
	•	Produce a plan: steps, sub-tasks, and boundaries.
	•	Produce code snippets showing approaches for specific files/functions.
	•	When needed, produce full patches for infrastructure or orchestrator, especially when the problem is architectural rather than a simple bug.
	•	Authority:
	•	Can propose new files, refactors, or structural changes.
	•	Can generate full patches, but Engineer remains the primary patch author for most work.
	•	Collaboration Loop:
	•	Planner breaks down the problem and hands snippets + plan + suggested patches to Engineer.
	•	Engineer implements, cleans up, and finalizes patches.

3.4 Human
	•	Role: Top-level owner.
	•	Responsibilities:
	•	Provide high-level intent (“Build Stage 1 homelab for prox-n100 cluster”).
	•	Approve or revert major architectural changes.
	•	Occasionally curate backlog tasks and manually run orchestrator/CLI.

⸻

4. Escalation & Collaboration Flow (Stage 0 / Stage 1)

We use a cyclical collaboration loop, not a one-way escalation.

The loop looks like:
	1.	Executor attempts a task
	•	Runs the target script/command via SSH or locally.
	•	If it succeeds → marks task completed.
	•	If it fails:
	•	Records logs + error context.
	•	Retries a small number of times (e.g., 2–3).
	•	If still failing → escalate to Engineer.
	2.	Engineer takes over
	•	Reads error context, logs, and relevant code.
	•	Applies fixes (code/config/small refactors) to address the underlying problem.
	•	Hands control back to Executor to re-run the task.
	•	If Engineer cannot find a clear fix after several attempts or issues seem systemic:
	•	Escalate to Planner.
	3.	Planner gets involved
	•	Analyzes the deeper pattern: architecture, design, workflow issues.
	•	Produces:
	•	A plan (steps, priorities).
	•	Snippets and, if warranted, full patches for tricky areas.
	•	Hands this plan + snippets to Engineer.
	4.	Engineer implements Planner’s plan
	•	Converts Planner’s snippets and patch suggestions into concrete, consistent changes.
	•	Runs local tests/sanity checks.
	•	Hands control back to Executor.
	5.	Executor reruns the task
	•	If success → task moves to completed.
	•	If still failing → loop repeats with more context, or flag for human review if we hit a global cap on retries.

This model allows Planner & Engineer to efficiently manage the repo together, while Executor focuses on executing tasks and verifying behavior.

⸻

5. State Machine & Task Status

Tasks in ai/backlog.yaml move through a strict state machine enforced by ai/orchestrator/lib/util_tasks.sh and related helpers.

Core states (conceptually):
	•	pending → running → (completed | failed | escalated | blocked | waiting_retry | review)

Key rules:
	•	A task must go pending → running before it can reach a terminal state like completed or failed.
	•	Invalid transitions (e.g., pending → failed, pending → escalated) should be treated as bugs in the orchestrator/persona logic, not normal operation.
	•	Each persona (Executor, Engineer, Planner) should:
	•	Set running when they begin real work.
	•	Update to waiting_retry or escalated or failed based on the outcome and retry policies.
	•	Metrics in ai/state/metrics.json should track:
	•	How many failures per task.
	•	What error types occur.
	•	When to escalate or require human review.

If you find illegal transitions or confusing state flows, prioritize small, surgical fixes to the orchestrator logic and persona handlers over big rewrites.

⸻

6. Safety & SSH on the N100

The Executor persona, via Codex CLI and orchestrator scripts, can run commands on the N100 over SSH.

Safety constraints for now:
	•	Do NOT reboot the N100.
	•	Avoid:
	•	Reboots
	•	Power-off commands
	•	Directly wiping disks
	•	It is acceptable to:
	•	Run bootstrap scripts.
	•	Run test commands.
	•	Inspect logs and status.
	•	Interact with Talos/K8s/proxmox tooling, as long as it’s part of an orchestrated, purposeful task and not random experimentation.

If in doubt, prefer to:
	•	Propose a script or change rather than immediately running a risky command.
	•	Include a comment or explanation for the human to review.

⸻

7. Patching & Approvals

For Stage 0 / Stage 1:
	•	You have permission to modify orchestrator logic and homelab code/configs as needed to make Stage 1 buildable and maintainable.
	•	Patches can be applied automatically, but you should:
	•	Keep them small and coherent.
	•	Explain what you changed and why.
	•	Avoid massive multi-file rewrites in a single step.
	•	When Planner generates large or structural patches, Engineer should:
	•	Integrate them carefully.
	•	Ensure consistency and readability.
	•	Avoid surprising, repository-wide changes without clear justification.

⸻

8. Scope: Stage 0 & Stage 1 Only (for Now)

There are future stages (AI Studio, multi-business engine, etc.), but:

For now, consider all later stages paused and out of scope.

Your objective is:
	1.	Make the orchestrator (Stage 0) stable, predictable, and understandable.
	2.	Enable the orchestrator + Codex CLI to reliably build and maintain the homelab (Stage 1) from human input.

That means your priority order is:
	1.	Fix orchestrator bugs (state machine, personas, logging).
	2.	Ensure tasks for Stage 1 (Proxmox/Talos/K8s) are reliable and debuggable.
	3.	Avoid over-designing future AI Studio or business logic for now.

⸻

9. How to Help Most Effectively

When I, the human, ask for help:
	•	First: understand.
Read relevant orchestrator, state, and task files. Explain them back to me.
	•	Second: localize the issue.
Identify exactly where the failure or bad transition originates.
	•	Third: propose a small plan.
Describe the change across 1–3 files.
	•	Fourth: implement small diffs.
Use minimal edits and explain each change.
	•	Fifth: suggest tests.
Help me add smoke-tests or checks so regressions are less likely.

You are allowed to think big, but you must change code small.

