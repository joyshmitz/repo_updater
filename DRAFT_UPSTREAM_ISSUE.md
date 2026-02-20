# Draft: Upstream Issue for Dicklesworthstone/repo_updater

> **Status:** DRAFT — review before submitting
> **Target:** https://github.com/Dicklesworthstone/repo_updater/issues/new
> **Strategy:** Problem statement with data. Reference implementation as evidence, not as PR.

---

## Title

Commit hygiene problem in multi-agent workflows — no tooling for grouping dirty worktrees into logical commits

## Body

### Problem

When multiple AI agents work across repos, they produce dirty worktrees with mixed changes — source edits, test additions, doc updates, config tweaks — all interleaved. Currently there is no tool that turns a dirty worktree into clean, atomic, conventional commits.

The agents are good at coding. They are bad at committing. This creates:

| Symptom | Example |
|---------|---------|
| **Mixed commits** | `git add . && git commit -m "updates"` bundles source + test + docs |
| **Bad messages** | `"fix stuff"`, `"wip"`, `"changes"` — no conventional commit structure |
| **Cross-agent pollution** | Agent A commits Agent B's uncommitted files because both touched the same worktree |
| **Unreadable history** | `git log` becomes noise; `git bisect` is useless |

This is different from orchestration (`agent-sweep` handles *which* repos to process). This is about *what happens to the dirty files* after the agent finishes coding.

### Why existing tools don't cover this

Unlike fork management (where `gh repo sync` covers the core action), there is no existing tool for automated commit grouping:

| Tool | What it does | What it doesn't do |
|------|-------------|-------------------|
| `git add -p` | Interactive hunk staging | No automation, no classification, no message generation |
| `git commit --fixup` | Amend previous commits | Doesn't group new changes |
| Pre-commit hooks | Lint/format before commit | Don't classify or group files |
| `agent-sweep` | Orchestrates agents across repos | Doesn't handle commit structure |
| `gh` CLI | Everything GitHub | Nothing for local commit organization |

There is no `gh commit-group` or equivalent. This is a gap in the toolchain.

### What a solution looks like

A dedicated command that:

1. Scans dirty worktrees (reuses `get_all_repos()`, `repo_is_dirty()`)
2. Classifies changed files into buckets: **source / test / doc / config**
3. Determines conventional commit type from bucket + git status:
   - `test/*` → `test:`, `*.md` → `docs:`, `.github/*` → `chore:`
   - source + Added → `feat:`, source + Modified → `fix:`, source + Renamed → `refactor:`
4. Extracts scope from top-level directory
5. Extracts task ID from branch name (e.g. `feature/bd-4f2a` → includes `(bd-4f2a)` in message)
6. Outputs a plan (dry-run by default), executes with explicit opt-in
7. JSON output via `build_json_envelope()` for downstream tooling

All heuristic, no LLM. Deterministic, reproducible.

### Data from a reference implementation

I built this in my fork (`joyshmitz/repo_updater`, branch `feature/commit-sweep`) as `ru commit-sweep`. Illustrative output from the test suite:

```
$ ru commit-sweep --json | jq '.data.summary'
{
  "repos_scanned": 3,
  "repos_dirty": 2,
  "repos_clean": 1,
  "planned_commits": 5,
  "commits_succeeded": 5,
  "commits_failed": 0
}
```

A repo with 5 dirty files (2 source, 1 test, 1 doc, 1 config) produces 4 atomic commits instead of 1 mixed commit. Each with a conventional message, scope, and task ID.

Example generated messages:
```
fix(session): fix session issues (bd-4f2a)
test(scripts): update scripts tests (bd-4f2a)
docs(root): update root documentation
chore(.github): update .github configuration
```

### Implementation notes

The reference implementation:
- ~840 lines of Bash, 15 functions with `cs_` prefix
- Reuses existing `ru` infrastructure: `build_json_envelope()`, `repo_preflight_check()`, `dir_lock_acquire()`, `is_file_denied()`, `resolve_repo_spec()`
- 35 unit tests + 12 E2E tests (following upstream patterns from `test_unit_parsing_coverage.sh` and `test_e2e_framework.sh`)
- NUL-safe `git status --porcelain=v1 -z` parsing
- Per-group rollback on commit failure
- Protected branch guard (refuses `main/master/release/*` without explicit flag)
- `--respect-staging` preserves manually staged files as a separate group
- Adversarial edge cases handled: filenames with commas/quotes, denylist enforcement on pre-staged files, partial commit failure tracking with non-zero exit codes

Dry-run is default; `--execute` is explicit opt-in — because creating commits is harder to undo than skipping them.

### Relationship to agent-sweep

This complements `agent-sweep`, not replaces it:

```
agent-sweep: "which repos need agent attention?" → orchestrate agents
commit-sweep: "what do we do with the mess agents left?" → organize commits
```

The natural workflow: `agent-sweep` dispatches coding agents → agents produce dirty worktrees → `commit-sweep` cleans up with atomic conventional commits.

### Not proposing a PR

Per CONTRIBUTING.md, this is a problem statement with a reference implementation, not a merge request. The working code at `joyshmitz/repo_updater@feature/commit-sweep` is reference material — adopt, adapt, ignore, or reimplement as you see fit.

---

<!-- Summary (structured, for automated triage) -->

```yaml
type: feature-gap
component: commit-workflow
severity: quality-of-life
existing_workaround: none
reference_implementation: joyshmitz/repo_updater@feature/commit-sweep
test_coverage: 47 tests (35 unit + 12 e2e)
dependencies: none (reuses existing ru infrastructure)
breaking_changes: none (new command, no modifications to existing commands)
```

---

> **Notes for ourselves (do NOT include in issue):**
>
> - Keep tone neutral/technical, not salesy
> - aspiers' bug reports worked because they were specific + had analysis
> - Our #1 initially got positive response then was rejected for "UX polish, not new capability"
> - Key differentiator: unlike fork-management, there is NO existing tool for this
> - Don't mention "50+ agents" — we learned that from conversation, not public info
> - Don't oversell the roadmap (v0.2-v0.5) — focus on v0.1 value
> - If he responds positively but wants to reimplement: great, that's the expected outcome
> - If he says "my agents already handle this internally": ask what approach, learn from it
> - The pirate/SpongeBob tone from issue #1 comment #3 was a mistake — keep it dry
> - "Results from real usage" was dishonest if from test suite — changed to "Illustrative output from the test suite"
> - Added explicit callback to #1 rejection reasoning ("Unlike fork management where gh repo sync covers the core action") — shows we listened
> - YAML metadata block at bottom is for agent triage — GitHub renders it as code, humans skip it, agents parse it
