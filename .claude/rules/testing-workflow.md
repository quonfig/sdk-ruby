---
description: Testing workflow rules for all code projects
globs: ["app-quonfig/**", "www-quonfig/**", "ai-starter/**", "api-telemetry/**", "api-delivery/**", "sdk-node/**", "sdk-go/**"]
---

IMPORTANT: Default to TDD — write the failing test first, run it and confirm it fails (red), then implement until it passes (green). The red→green sequence is the cheapest check that the test is real and that the change actually worked. Paste both the failing and passing output as evidence.

IMPORTANT: The goal is **verification**, not test volume. If a change genuinely isn't red/green testable in code (UI polish, infra glue, config-only changes, anything where the test rig would be more complex than the fix), pick one:
1. **Simulated verification** — drive the real flow (browser automation, live HTTP call, dev server) and paste the evidence it worked.
2. **Block for human** — `bd update <id> --status blocked --add-label needs-human` with a comment explaining what you tried and why verification needs human hands. Do NOT `bd close` — that hides the bead from the human queue.

Never ship with zero verification. Don't build elaborate test scaffolding when the change doesn't warrant it — the form can flex, the evidence cannot.

IMPORTANT: Run the relevant test suite before marking a task complete (the file or package you touched, not necessarily the whole repo).

## Browser / Chrome DevTools testing (app-quonfig)

When any task requires browser testing in app-quonfig, ALWAYS read these skills first:
- `/user-test-login`  — `.claude/skills/user-test-login/SKILL.md`
- `/user-create-test` — `.claude/skills/user-create-test/SKILL.md`

Key points so you don't go off-script:
- Test accounts live in `app-quonfig/.dev/test-users.json` (gitignored, alias-keyed)
- The dev-agent login route (`POST /api/dev/login-as`) is the preferred way to sign in headlessly — requires `DEV_AGENT_LOGIN=true` in `.env`
- Use `isolatedContext` in Chrome MCP when you need a clean session that doesn't share cookies
- Avoid `@example.com` emails — that domain triggers SSO via the Test Organization
- Verification codes for new sign-ups come from the WorkOS Events API (see `/user-create-test` for the node snippet)
- If a test requires a user with a specific state (e.g. pending invite, no org), create a fresh account with `/user-create-test` rather than reusing an existing one
