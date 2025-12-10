# Orchestrator v2 - README

The Funoffshore Homelab Orchestrator v2 is a multi-layer control system designed to operate, repair, and continuously converge a Talos-based Kubernetes environment running on Proxmox.

## Quick Start

### Prerequisites

- Python 3.x with `yaml` module
- `jq` for JSON processing
- `git` for version control
- `talosctl` for Talos management
- `kubectl` for Kubernetes access
- (Optional) Codex CLI for local executor
- (Optional) `OPENAI_API_KEY` for API escalation

### Running the Orchestrator

```bash
# Run a single stage
./ai/bootstrap_loop.sh talos

# Run all stages
./ai/bootstrap_loop.sh all

# Check current status
./ai/bootstrap_loop.sh status

# Reset a stage
./ai/bootstrap_loop.sh talos --reset
```

### Stages

| Stage | Description |
|-------|-------------|
| `vms` | Proxmox VM creation for Talos nodes |
| `talos` | Talos Kubernetes bootstrap |
| `infra` | Flux + core platform (storage, etc.) |
| `apps` | Homelab applications |
| `ingress` | Ingress controller, Cloudflare tunnel |
| `obs` | Observability stack |

## Architecture

The orchestrator follows a layered architecture:

```
┌─────────────────────────────────────────────────────────────┐
│                      Human (Architect)                       │
│  - Maintains master_memo.md                                  │
│  - Reviews and merges AI changes                             │
│  - Intervenes for give_up states                             │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                   OpenAI API (Escalation)                    │
│  - Deep cross-file reasoning                                 │
│  - Returns patches or diagnostics requests                   │
│  - Max 3 calls per escalation                                │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                   Executor (Codex/Local LLM)                 │
│  - Handles new errors                                        │
│  - Makes small, local fixes                                  │
│  - Curates context for escalation                            │
│  - Executes diagnostics                                      │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                   Plumbing (bootstrap_loop.sh)               │
│  - Runs stages                                               │
│  - Captures logs                                             │
│  - Computes error hashes                                     │
│  - Decides escalation                                        │
└─────────────────────────────────────────────────────────────┘
```

## File Structure

```
ai/
├── bootstrap_loop.sh       # Main orchestrator entry point
├── executor_runner.sh      # Executor interface
├── case_file_generator.sh  # Generates case files for API
├── api_client.sh           # OpenAI API client
├── diagnostics_runner.sh   # Runs diagnostic commands
├── context_map.yaml        # Stage-to-file mappings
├── master_memo.md          # Canonical architecture
├── executor_instructions.md # Executor behavior contract
├── backlog.md              # Dynamic task backlog
├── issues.txt              # Known issues log
├── state/
│   ├── errors.json         # Error tracking per stage
│   └── stage_status.json   # Stage status (idle/green/failed/give_up)
├── logs/
│   ├── talos/              # Talos stage logs
│   ├── vms/                # VM stage logs
│   ├── diagnostics/        # Diagnostic outputs
│   └── ...
├── escalations/            # Case files and patches
└── patches/                # Executor-generated patches
```

## Workflow

### Normal Flow

1. **Run Stage**: `bootstrap_loop.sh` executes the stage command
2. **Log**: Output saved to `ai/logs/{stage}/`
3. **Hash**: Error hash computed from log tail
4. **Track**: Attempt count updated in `errors.json`
5. **Decision**:
   - If attempts < 3: Executor attempts local fix
   - If attempts >= 3: Escalate to API

### Escalation Flow

1. **Case File v1**: Executor builds case file with context
2. **API Call**: OpenAI analyzes and responds with:
   - **Patch**: Unified diff to apply
   - **Diagnostics**: Commands to run for more info
3. **Apply/Diagnose**:
   - Patch: Apply and re-run stage
   - Diagnostics: Run commands, build Case File v2
4. **Case File v2**: Send with diagnostic outputs
5. **Final Patch**: Apply and re-run stage

### Give Up

If after 3 API calls the error persists, the stage enters `give_up` state:
- Human intervention required
- Review case files in `ai/escalations/`
- Fix manually and reset: `./ai/bootstrap_loop.sh <stage> --reset`

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENAI_API_KEY` | (required) | API key for escalation |
| `OPENAI_MODEL` | `gpt-4-turbo-preview` | Model for API calls |
| `EXECUTOR_RETRY_THRESHOLD` | `3` | Attempts before escalation |
| `API_CALL_BUDGET` | `3` | Max API calls per escalation |
| `AI_BRANCH` | `ai/orchestrator-stage1` | Git branch for AI changes |

### Context Map

Edit `ai/context_map.yaml` to customize:
- Files relevant to each stage
- Architecture sections to include
- Success criteria
- Diagnostic commands

## Safety Invariants

The orchestrator enforces these rules:

1. **Protected Files**: These cannot be modified by AI:
   - `ai/master_memo.md`
   - `ai/context_map.yaml`
   - `ai/bootstrap_loop.sh`
   - `infrastructure/proxmox/wipe_proxmox.sh`

2. **Side Branch**: All AI changes go to `ai/orchestrator-stage1`

3. **Bounded Escalation**: Max 3 API calls per error

4. **No New Directories**: AI cannot create top-level directories

5. **Minimal Patches**: Changes must be small and reversible

## MVP: Talos Stage

The MVP focuses on the Talos stage:

```bash
# Run Talos stage only
./ai/bootstrap_loop.sh talos
```

### Success Criteria

- Talos VMs created on Proxmox
- Nodes boot and expose Talos API
- `talosctl get machines` returns correct state
- Kubernetes API accessible

### Common Issues

1. **VM creation fails**: Check Proxmox storage and networking
2. **Talos config fails**: Verify IPs in `config/clusters/prox-n100.yaml`
3. **Bootstrap hangs**: Check Talos API accessibility

## Debugging

### View Logs

```bash
# Recent stage logs
ls -la ai/logs/talos/

# View specific log
cat ai/logs/talos/talos_20231207-120000_attempt1.log
```

### Check State

```bash
# Current status
./ai/bootstrap_loop.sh status

# Error tracking
cat ai/state/errors.json
```

### View Escalations

```bash
# Case files and patches
ls -la ai/escalations/
```

### Manual Reset

```bash
# Reset a stuck stage
./ai/bootstrap_loop.sh talos --reset
```

## Contributing

1. AI changes go to `ai/orchestrator-stage1` branch
2. Human reviews and merges to `main`
3. Update `master_memo.md` for architectural changes
4. Update `context_map.yaml` for new file mappings

---

*For the full v2 architecture specification, see `docs/orchestrator_v2.txt`*
