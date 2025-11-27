# Daily Digest Workflow (Stub)

This workflow is part of the **Biz2: AI Studio** charter. See `projects/biz2/README.md` for the mission, guardrails, and how digests feed into Biz2 experiments.

1. **Gather Sources**
   - Capture RSS/news/blog links into `memory/news/` with timestamped Markdown files (one file per source batch).
   - Include context tags (infra, biz, research) in a small frontmatter block.

2. **Summarize Locally**
   - Use Ollama models defined in `config.yaml` (qwen2 for summaries, deepseek-coder for code-heavy items).
   - Store generated summaries under `news_digest/<date>-digest.md` with YAML frontmatter describing scope, sources, and owners.

3. **Backlog + Follow-ups**
   - Record new actions in `ai/studio/backlog.md` under "Experiment Ideas".
   - If any infra work is needed, open an item in the main `ai/backlog.md`.

Use `python3 ai/studio/main.py --workflow daily_digest` for a CLI reminder of these steps.
