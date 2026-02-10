# Lessons Log

Purpose: single place to capture practical lessons for human operator control of agent workflows.

## Usage Rules

- Add one entry per lesson with date, context, signal, action, and prevention.
- Keep entries short and operational.
- Prefer concrete commands over narrative.

## Entry Template

```
## YYYY-MM-DD — Short title

Context:
- ...

Signal:
- ...

Root cause:
- ...

Action taken:
- `...`

Validation:
- `...`

Prevention:
- ...
```

## 2026-02-10 — bv/br stopped due to invalid JSONL

Context:
- Agents in `/data/projects/repo_updater` stopped making progress.
- `bv` TUI/robot outputs became unreliable.

Signal:
- `br ready --json` returned `CONFIG_ERROR` (invalid JSON, missing `created_at`).
- `bv` reported many `invalid issue type` warnings and showed no usable issues.

Root cause:
- `.beads/issues.jsonl` became incompatible/corrupted for current parser expectations.
- Source of truth (`.beads/beads.db`) remained valid.

Action taken:
- Re-exported JSONL from DB:
- `cd /data/projects/repo_updater`
- `BEADS_JSONL=.beads/issues.jsonl br sync --flush-only --force -v`

Validation:
- `br ready --json` returned valid issue list.
- `bv --robot-next` returned a recommendation.
- `bv` TUI launched and displayed the issue table normally.

Prevention:
- Before agent sessions, run:
- `br ready --json >/dev/null`
- `bv --robot-next >/dev/null`
- If either fails with JSON/config errors, immediately run the recovery sync command above.
