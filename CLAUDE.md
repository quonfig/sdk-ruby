# Quonfig Ruby SDK

Ruby SDK for Quonfig feature flags and configuration.

## Build & Test

```bash
bundle install                          # install dependencies
bundle exec rake test                   # run all tests
bundle exec ruby test/test_FOO.rb       # run a single test file
bundle exec rake                        # default task — runs tests
```

## Directory layout

- `lib/quonfig/` — SDK source code
- `test/` — unit tests (one `test_*.rb` per module)
- `test/integration/` — integration tests driven by shared YAML specs

Integration tests require the sibling directory `../../integration-test-data/`
to exist (cloned from `quonfig/integration-test-data`). Without it the
integration suite cannot resolve its YAML specs.

## Environment variables

- `QUONFIG_BACKEND_SDK_KEY` — backend SDK key for authenticated config delivery
- `QUONFIG_DIR` — path to a local Quonfig workspace (datadir mode)
- `QUONFIG_ENVIRONMENT` — which environment to evaluate (`production`, `staging`, `development`)
- `QUONFIG_DOMAIN` — base domain used to derive api/sse/telemetry URLs (default `quonfig.com`). Setting `QUONFIG_DOMAIN=quonfig-staging.com` derives `https://primary.quonfig-staging.com`, `https://stream.primary.quonfig-staging.com`, and `https://telemetry.quonfig-staging.com` automatically. Explicit `api_urls:` / `telemetry_url:` kwargs override this.

## Fork model (Ruby 3.1+)

The SDK installs a `Process._fork` hook (`Quonfig::ForkSafety` in
`lib/quonfig/client.rb`) at load time. Every `Quonfig::Client` instance is
tracked in an `ObjectSpace::WeakMap` on the class.

**The hook is child-only. The parent is never touched.** This is Reforge's
model (`Reforge.fork` builds a new client in the child and never touches the
old one) and matches dd-trace-rb, redis-client, and connection_pool, which
all branch on the child stage of `_fork` only.

- **In the parent:** nothing happens. Not before the syscall, not after it.
  The SSE stream, poller, telemetry reporter, and datadir watcher all keep
  running, so a process that forks workers and keeps evaluating stays
  current.
- **In the child, after the syscall:** `after_fork_in_child` does NO I/O. It
  drops the inherited references (`@sse_client`, `@poll_supervisor`,
  `@telemetry_reporter`, `@datadir_watcher`, `@fallback_engage_timer`)
  **without** calling `close`, `stop`, or `join` on them, swaps in fresh
  mutexes, resets the SSE state machine, replaces `@store` (plus the
  evaluator, resolver, and config loader that read it) with a brand-new empty
  one, allocates fresh telemetry + failover aggregators, and sets
  `@fork_rebuild_pending`. Skipped if `stop` was called.
- **On the child's first use of the client:** `ensure_initialized_after_fork`
  (called from `get`, `evaluate_details`, `defined?`, `keys`, and the public
  `store` / `resolver` / `evaluator` / `config_loader` readers) runs what
  `Client.new` runs — its own blocking config fetch under `init_timeout_ms` /
  `on_init_failure`, then its own SSE (or fallback poller) and its own
  telemetry reporter — and logs one info line. **The child never evaluates
  from the parent's config snapshot**: its store starts empty and it fetches
  its own. A child that never uses the client costs nothing (no fetch, no
  socket, no thread), and `stop` in such a child returns immediately.
  `connection_state` deliberately does NOT trigger the rebuild — a diagnostic
  must not open a socket — and reports `:initializing` while one is pending.

Four rules that keep the lazy rebuild honest (qfg-lv4n.1, second adversarial
pass):

- **`@fork_rebuild_pending` stays TRUE for the whole rebuild.** It is cleared
  inside `rebuild_in_child!`, at the point the child has a live path to
  config — not by the caller before the work. That is what makes concurrent
  first-use callers block on the mutex instead of sailing past on the
  unlocked fast path and reading the empty store, and it is what re-arms the
  rebuild when a non-`StandardError` (`Timeout::ExitException`, rack-timeout,
  `Thread#kill`) escapes. `@fork_rebuild_owner` is the same-thread guard so a
  logger that evaluates a config from inside the rebuild cannot deadlock.
- **`stop` raises `@stopped` BEFORE it queues for `@fork_rebuild_mutex`**, so
  an in-flight rebuild skips `start_update_channel` and the reporter
  entirely; the teardown then runs under that lock so it never interleaves
  with construction.
- **The failure path is mode-aware.** Network clients start the update
  channel so SSE can heal; datadir clients must NOT (they have no config
  loader — every envelope would raise) and instead start the watcher or
  re-arm the rebuild.
- **`after_fork_in_child` early-returns in a process that owns live
  components.** Threads do not survive `fork(2)` and the reporter stamps an
  owner pid, so this is false in a real child and true in the parent — which
  makes the 1.0–1.3 "call it in the parent" workaround a harmless no-op
  instead of an orphaned stream per call.

Two rules the child must never break:

- **Never close the inherited SSE socket.** `fork(2)` duplicates the fd, so
  the child's copy points at the connection the *parent* is streaming on.
  Closing a TLS socket writes `close_notify` onto that shared connection and
  kills the parent's stream. (Verified: closing a child's copy of a plain TCP
  socket leaves the parent's connection working; TLS does not have that
  property.)
- **Never join an inherited thread.** It does not exist in the child, so the
  join blocks forever — LaunchDarkly ruby-server-sdk PR #430.

Coverage and limits:

- Covers any path that goes through `Process._fork` (Ruby's `Process.fork`,
  `Kernel#fork`, the `parallel` gem, a `fork { }` inside a Sidekiq job).
  Does NOT cover `Process.spawn` or `system("...")` — those exec a new
  program, so in-process SDK state does not carry across.
- Ruby 3.0 lacks `Process._fork`; on 3.0 customers wire `Quonfig.fork` into
  Puma's `on_worker_boot` (or the top of the forked block) manually — see
  README "Rails integration".
- `Client#before_fork_in_parent` still exists for semver but is
  `@deprecated`: the hook no longer calls it. Use `stop` if you want a client
  dead.
- `connection_state` derives from **liveness**, not from the stored
  `@sse_state`. A network client that is supposed to hold an SSE stream and
  has no live worker reports `:disconnected`. Regression history: the
  pre-1.4.0 hook left `@sse_state == :connected` behind after tearing the
  parent down, and a customer's dark Sidekiq process reported healthy for 13
  days (qfg-lv4n).

## Local development

Two ways to point the SDK at a local stack:

1. **Explicit URL overrides** (zero infra): pass `api_urls:` and `telemetry_url:`
   directly to the constructor, pointing at `http://localhost:6550` and
   `http://localhost:6555`. This is the simplest path for SDK unit tests.

2. **`QUONFIG_DOMAIN=quonfig-localhost`** (production-like routing): start the
   bundled Caddy reverse proxy at the monorepo root with
   `scripts/local-proxy/setup.sh`. Then `QUONFIG_DOMAIN=quonfig-localhost`
   resolves to `https://primary.quonfig-localhost` /
   `https://stream.primary.quonfig-localhost` / `https://telemetry.quonfig-localhost`,
   all proxied to the local api-delivery (:6550) and api-telemetry (:6555).
