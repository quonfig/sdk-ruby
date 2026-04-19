---
description: Git safety rules applied to all projects in the monorepo
globs: ["**"]
---

IMPORTANT: Never force push (`--force` or `--force-with-lease`) to any branch.
IMPORTANT: Never delete branches without explicit user approval.
IMPORTANT: Never run `git reset --hard` or `git clean` without explaining what will be lost and getting confirmation first.
IMPORTANT: Always commit work-in-progress before any context switch so nothing is lost.
IMPORTANT: Keep commits small and well-scoped so anything can be easily reverted.
IMPORTANT: If git blocks an operation, stop and ask — don't force past it.
