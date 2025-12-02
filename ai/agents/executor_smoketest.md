# Executor Smoketest Agent (safe, read-only)

Purpose: verify Codex CLI wiring and repo visibility without touching the cluster or running SSH.

Instructions for Executor:
- Print a small header/banner (cwd, timestamp, resolved profile if any) to confirm you are alive.
- Run only local, read-only commands:
  - `pwd`
  - `ls`
  - `ls scripts` && `ls infrastructure/proxmox` && `ls ai`
  - `git status --short`
  - `head -n 20 scripts/ai_harness.sh infrastructure/proxmox/cluster_bootstrap.sh`
- Do NOT run SSH, do NOT edit files, do NOT invoke cluster scripts.
- Summarize what you saw (presence and readability of ai_harness.sh, cluster_bootstrap.sh, agents) and print a friendly “ready to run bootstrap when requested” message.

Stop after printing the summary. This is a smoke check, not a bootstrap.
