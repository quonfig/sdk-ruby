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
- `QUONFIG_TELEMETRY_URL` — telemetry ingest endpoint
