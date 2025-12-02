# Prototype Loop Workflow (Stub)

Grounded in the **Biz2: AI Studio** charter (`projects/biz2/README.md`), this loop runs the multi-agent harness from idea → prototype → recap.

1. **PM Intake** – Define the question/problem and success metric.
2. **Planner Guardrails** – Confirm tools, safety limits, and data boundaries.
3. **Engineer Build** – Outline steps, scripts, or notebooks to run locally.
4. **Researcher Validation** – Evaluate outputs, gather data, identify gaps.
5. **Marketer Packaging** – Summarize outcome, value, and next experiment.

Document each pass in `memory/experiments/<slug>.md` and publish a recap into `reports/research/<slug>-recap.md`. Run `python3 ai/studio/main.py --workflow prototype_loop` to print this checklist.
