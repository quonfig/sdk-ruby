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
