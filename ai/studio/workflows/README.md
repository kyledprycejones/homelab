# AI Studio Workflows

Entrypoints for daily digests, SRE checks, news pipelines, and other multi-step orchestrations.

## Required Stubs (Biz2)
- `daily_digest.py` / `daily_digest.md`: collects news sources -> summarizer -> report drop into `news_digest/`. (See `daily_digest.md` stub.)
- `prototype_loop.py` / `prototype_loop.md`: PM request -> Planner guardrails -> Engineer tasks -> Researcher validation -> Marketer pack-up. (See `prototype_loop.md` stub.)
- `ops_health.py`: optional, monitors homelab services once Biz2 prototypes exist.

Workflow scripts can start as Markdown guides (like the stubs above) before evolving into runnable Python modules invoked by `main.py`.
