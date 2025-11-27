# AI Studio Memory Schema

Biz2 keeps working data in Git so agents can reason about it offline. The `memory/` tree is intentionally simple and text-first.

## Directories
- `architecture/` – notes on system diagrams, decisions, and env wiring.
- `experiments/` – running logs for Biz2 prototype loops (`prototype_loop` workflow).
- `interviews/` – structured interviews, user notes, and qualitative feedback.
- `marketing/` – positioning notes, headline drafts, and launch ideas.
- `news/` – raw news/RSS/blog captures used by the daily digest.

You can add more subdirectories as needed, but keep names human-readable and scoped to Biz2 work.

## File format
- Preferred: Markdown with a small YAML frontmatter block.
- Optional: JSON files when a downstream script wants a strict schema.

### Recommended frontmatter keys
- `title`: short, human-friendly label.
- `slug`: filesystem-safe identifier (`biz2-digest-2025-01-01`).
- `date`: ISO8601 timestamp (`2025-01-01T12:00:00Z`).
- `owner`: who drove the work ("hands", "junior", or a real name).
- `tags`: list like `["biz2", "digest", "infra"]`.
- `status`: e.g. `draft`, `in_progress`, `final`.

### Naming conventions
- News batches: `news/YYYYMMDD-HHMMZ-<slug>.md`.
- Experiments: `experiments/<slug>.md`.
- Interviews: `interviews/YYYYMMDD-<subject>-<slug>.md`.
- Architecture notes: `architecture/<area>-<slug>.md`.

## Retention expectations
- Keep raw `news/` items for ~90 days unless they feed a long-running experiment.
- Keep `experiments/` and `interviews/` indefinitely (they document Biz2 history).
- Avoid storing secrets, tokens, or private customer data here.

If a file feels sensitive or long-lived, link to it from a report in `reports/` instead of pasting the full contents.

