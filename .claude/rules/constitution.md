---
name: constitution
description: Rules for when agents must stop for human review vs. proceed autonomously. Read before committing significant changes or when uncertain about scope.
---

# Agent Constitution

Default rule: **when in doubt, block for human review**. A false positive costs 30 seconds. A false negative can cause real damage.

Human-review blocks use the built-in `blocked` status plus the `needs-human` label (bd's custom-status format doesn't accept `blocked:human`). Do NOT call `bd close` on a bead that needs human input — closed beads are invisible to the human review queue.

## Auto-Proceed (no human needed)

- Bug fixes with passing tests
- UI copy, labels, and styling changes
- Test coverage additions
- Refactoring within a single file that doesn't change public interfaces
- Docs and comment updates
- Simulation-discovered bugs with a clear root cause and fix
- Patch-version dependency bumps
- Adding new flags/configs to `our-config/` (no schema change)
- **Data-only edits** to existing configs in `our-config/` — flipping a boolean, editing a value, renaming a label. Changing *what* is stored is a data change; changing *how* it's stored is a schema change.
- Staging deployments (`fly.staging.toml`)

## Stop and Ask (blocked + needs-human)

**Push as far as you can before blocking.** The goal is to surface a specific,
answerable question — not to stop at the first sign of uncertainty. Investigate the
codebase, try the obvious path, and block only when you hit a concrete fork that
requires a human judgment call. An agent that does real work and then blocks with a
precise question is far more valuable than one that blocks immediately.

Block when you reach a decision point that touches:

- **Storage format** — git repo structure, JSON config schema, Gitea config
- **SDK-facing API surface** — anything SDK clients call: `api-delivery` endpoints, SSE protocol, SDK public interfaces
- **Cache or delivery protocol** — how configs are loaded, evicted, or streamed
- **Auth and access control** — workspace permissions, API keys, OAuth flows
- **New external dependencies** — adding a package to package.json, go.mod, etc.
- **Database schema changes** — Drizzle migrations, ClickHouse schema
- **Multi-service contract changes** — modifying interfaces shared between two or more services
- **High uncertainty** — you've investigated and the right approach still isn't clear

When blocking, be specific: explain exactly what decision is needed, what you've
already ruled out, and what the options are. Vague blocks ("not sure how to proceed")
are not acceptable — do more investigation first.

```bash
bd update <id> --status blocked --add-label needs-human
bd comments add <id> "Blocked: [what the decision is, what you investigated, what the options are]"
```

To see the human-review queue: `bd list --label needs-human`. Do NOT call `bd close` on these — the label is what surfaces them.

## Never Touch Without Explicit Instruction

- Credentials, secrets, `.env` files with real values
- Live production data or the Gitea service token
- Anything in `business/`
- Production fly deployments (`fly.toml` or `fly.production.toml`, not `fly.staging.toml`)
- The `.beads/` database directly (always use `bd` CLI)

## Alpha Phase Rules

In alpha it is acceptable to:
- Deploy to staging without asking
- Commit directly to main in sub-repos
- Run simulated user tests against the local dev server
- File new beads for bugs found during simulation

It is NOT acceptable to:
- Deploy to production without asking
- Modify `integration-test-data/` YAML without asking
- Merge breaking changes to SDK public APIs without asking

## Daily Digest

Append to `digests/YYYY-MM-DD.md` after each completed task:
- What was done and what tests passed
- What is blocked and why
- Any bugs filed by the simulate stage
