# Provenance & License Boundary

## Fork Identity

| Field | Value |
|-------|-------|
| **Origin** | `Dicklesworthstone/repo_updater` |
| **Fork** | `joyshmitz/repo_updater` |
| **Fork date** | 2026-01-06 |
| **License at fork** | MIT (plain) |
| **Our license** | MIT (plain) — see `LICENSE` |

## Provenance Freeze (2026-02-22)

On 2026-02-21, upstream changed their license from plain MIT to
**"MIT License with OpenAI/Anthropic Rider"** (commit `6f2db83`). The rider:

- Restricts use by OpenAI, Anthropic, and their affiliates
- Requires all derivative works to include the rider unmodified
- Is **not** OSI-compliant (violates OSD sections 5 and 6)

### Decision

**We do not merge any upstream code from commit `6f2db83` (2026-02-21) onward.**

### Rationale

1. **Our fork predates the rider by 46 days.** All upstream code in our
   repository was received under plain MIT. MIT grants are perpetual and
   practically irrevocable (*Jacobsen v. Katzer*, 2008; MetaMask precedent, 2020).

2. **Post-rider code carries propagation obligations.** The rider demands
   that "any distribution of Derivative Works must include this rider
   provision unmodified." Merging even one line of post-rider code could
   be construed as acceptance of those terms.

3. **The rider is incompatible with our workflow.** This project uses
   Claude (Anthropic) as a development tool. Accepting a license that
   restricts Anthropic creates an incoherent legal posture.

4. **We gain nothing from merging.** Upstream rejected our fork-management
   feature (issue #1, won't-fix). Their commit-sweep implementation
   (issue #6, 363 lines) is a minimal prototype; ours is 903 lines with
   atomic commits, structured JSON, locking, and rollback. There is no
   upstream code we need.

### Boundary

| Scope | License | Status |
|-------|---------|--------|
| Upstream code received before 2026-02-21 | MIT | In our repo, safe |
| Upstream code from `6f2db83` onward | MIT + Rider | **Never merged** |
| Our independent code (fork-mgmt, commit-sweep, tests) | MIT (our copyright) | Our terms |

### Policy Going Forward

- **Do not** `git merge upstream/main` or cherry-pick from upstream.
- **Do not** copy code from upstream's post-rider commits.
- If an upstream bugfix is needed, **reimplement independently** from the
  problem description, not from their code.
- The `upstream` remote may remain configured for reference, but no code
  flows from it into our branches.

### Last Clean Upstream Commit

```
1552bac  (last commit merged into origin/main before rider)
```

All commits in `origin/main` up to and including `1552bac` are clean MIT
provenance. Commit `6f2db83` and everything after it is off-limits.

## Timeline

| Date | Event | Commit |
|------|-------|--------|
| 2026-01-03 | Upstream repo created (MIT) | initial |
| 2026-01-06 | Fork created (MIT) | — |
| 2026-01-21 | Upstream explicit LICENSE commit (MIT) | — |
| 2026-02-21 | Upstream license changed to MIT+Rider | `6f2db83` |
| 2026-02-22 | **Provenance freeze declared** | this document |
