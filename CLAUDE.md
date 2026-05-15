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
tracked in an `ObjectSpace::WeakMap` on the class; on fork the hook fans out:

- **In the parent, before the syscall:** close SSE worker, polling
  supervisor, telemetry reporter. `@stopped` is NOT set — the client object
  stays usable, just thread-less.
- **In the child, after the syscall:** rebuild SSE, polling, and telemetry
  on the same `Client` object. Skipped if `stop` was called or the client is
  in datadir mode.

Coverage and limits:

- Covers any path that goes through `Process._fork` (Ruby's `Process.fork`,
  `Kernel#fork`). Does NOT cover `Process.spawn` or `system("...")` — those
  exec a new program, so in-process SDK state does not carry across.
- Ruby 3.0 lacks `Process._fork`; on 3.0 customers must wire Puma's
  `before_fork` / `on_worker_boot` manually (see README "Rails integration").
- The parent's threads stay closed after fork (mirrors the Puma master case,
  where the master no longer serves requests). If a topology needs the
  parent to keep streaming, customers can call
  `Quonfig.instance.after_fork_in_child` manually in the parent.

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
