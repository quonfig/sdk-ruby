# Changelog

## 0.0.17 - 2026-05-19

- **Feat (datadir): opt-in `data_dir_auto_reload` (qfg-mol-2da).** Datadir mode previously loaded the workspace once at construction and served purely from memory. Set `data_dir_auto_reload: true` to have the SDK watch the configured `datadir`, re-read `Quonfig::Datadir.load_envelope`, and fire the existing `on_update` callback whenever files change. Adds `listen ~> 3.8` (FSEvents on macOS, inotify on Linux, polling fallback on Windows) as a runtime dep. Behavior: parse-then-swap (a failed parse keeps the previous envelope and skips the callback), debounced (`data_dir_auto_reload_debounce_ms`, default 200 ms — bursts coalesce to one reload), and gracefully downgrades when watch registration fails (read-only fs, immutable container, missing native backend). Symlinked datadirs are resolved to their real path before watching. Default is `false`; opt-in only.
- **Feat (datadir + fork): auto-restart the watcher across `fork(2)` (qfg-mol-2da).** The watcher uses a background thread, which does not survive fork. The existing `Process._fork` hook (qfg-ryov, Ruby 3.1+) now also tears the datadir watcher down in the parent before fork and rebuilds a fresh one on the same `Client` in each child — no customer wiring required for Puma clustered mode, Unicorn, Sidekiq's parent-forks-workers model, Resque, or Spring. Ruby 3.0 customers continue to use the documented `Quonfig.fork` pattern in `on_worker_boot`, which rebuilds the watcher alongside the rest of the client.

## 0.0.16 - 2026-05-15

- **Feat (SSE): replace `ld-eventsource` with an SDK-owned reconnect loop (qfg-35sm).** sdk-ruby was the outlier among the four backend SDKs — sdk-go, sdk-node, and sdk-python all own their reconnect loop, only sdk-ruby handed it off to a library and scraped its log output to observe reconnects. The wire format we actually consume (plain JSON envelopes in single-line `data:` frames, no named events, no retry directives) is trivial enough that an SDK-owned loop is clearer than the library wrapper. New `Quonfig::SSEConfigClient` (~520 LoC, `lib/quonfig/sse_config_client.rb`) handles connect/parse/reconnect end-to-end. `restart_total` is now incremented at exactly one site under a mutex — verifiable, not log-scraped. `ld-eventsource` and the transitive `http` gem are removed from the gemspec. `ReconnectCountingLogger` and the `sse_reconnect_reset_interval` option (both 0.0.15-era defensive scaffolding around upstream behavior) are deleted — the bugs they defended against don't exist when the SDK owns the loop. Chaos: 10/10 in a 36-min run (scenarios 02 silent-stall, 05 sse-down-fallback, 09 flapping kill-storm).
- **Fix (SSE): contain watchdog `Thread#raise` with `Thread.handle_interrupt` (qfg-tj18).** The new watchdog fires `Thread#raise(SSEReadDeadlineExceeded)` into the worker on a silent stall — the only reliable cross-platform way to unblock a Ruby thread blocked in `Net::HTTP`'s body-read on macOS. The decision to fire is mutex-guarded against `stop()`, but the raise itself is delivered at the worker's next interrupt checkpoint, which could be anywhere in the call stack. `run_loop`'s body now runs under `Thread.handle_interrupt(SSEReadDeadlineExceeded => :on_blocking)` so a late-landing raise can only land inside a blocking call; the `read_body` block explicitly switches to `:immediate`. A paranoid backstop `rescue` outside the until-`@stopped` loop ensures an escaped raise can never silently kill the worker.
- **Fix (SSE): isolate `on_envelope` callback exceptions (qfg-m3lk).** A buggy user-supplied listener that raised during envelope delivery used to propagate out of `read_body`, get caught by `run_loop` as a transport error, bump `restart_total`, and reconnect — a perpetual reconnect storm at api-delivery-sse driven by a customer code bug. The callback is now wrapped in `begin/rescue StandardError` at the invocation site; exceptions are logged with class + message + backtrace sample and the stream continues uninterrupted. `Interrupt` and `SystemExit` are deliberately not caught so `Ctrl-C` still works.
- **Fix (SSE): classify 401/403/404 as terminal errors (qfg-i5xv).** Non-200 responses used to be treated identically — `SSEHTTPStatusError` raised, `run_loop` rescued, `restart_total` bumped, backoff, retry, forever. For a bad SDK key (401) or revoked workspace (403) that was wasted load on api-delivery-sse with no recovery path short of a customer redeploy. New `SSEHTTPTerminalError` sentinel for 401/403/404; `run_loop` catches it, invokes `on_error`, exits the loop without bumping `restart_total`. Parent `Quonfig::Client` surfaces a terminal `:sse_terminal_failure` state distinct from transient `:error`. 429 and 5xx still retry.
- **Feat (fork): install `Process._fork` hook so SSE auto-restarts after fork (qfg-ryov).** Ruby threads do not survive `fork(2)`. Customers initializing `Quonfig::Client` in the Puma master (the `preload_app! true` / Rails `config.eager_load = true` convention) used to silently lose SSE in every worker child. New `Quonfig::ForkSafety` module prepends `Process._fork` and fans out across all live `Quonfig::Client` instances (tracked in an `ObjectSpace::WeakMap`): in the parent before the syscall, threaded components (SSE worker, polling supervisor, telemetry reporter) are torn down; in the child after the syscall, they are rebuilt. `@stopped` is preserved so a `stop()`-ed client stays stopped across fork. Covers `Process.fork` / `Kernel#fork`; `Process.spawn` and `system("...")` exec a new program so in-process state doesn't apply. Ruby 3.0 lacks `Process._fork` and is documented as requiring manual `before_fork` / `on_worker_boot` wiring.

## 0.0.15 - 2026-05-15

- **Fix (SSE): count ld-eventsource internal reconnects (qfg-ie49).** ld-eventsource auto-reconnects on a clean socket FIN *internally* and never fires `on_error`, so the qfg-ll6r on_error-based `restart_total` counter sat at 0 under flapping outages (chaos scenario 09 — proxy killed 5x in 30s). `restart_total` now counts actual reconnects from two mutually-exclusive sources: ld-eventsource internal reconnects (observed via a pass-through logger wrapper that watches the per-reconnect `"Will retry connection after"` info line — the only hook the library exposes) and SDK-driven reconnects in `@retry_thread`. `on_error` is no longer a counting source.
- **Fix (SSE): backoff reset interval (qfg-ie49).** New `sse_reconnect_reset_interval` option, default `1s`. ld-eventsource's 60s default lets the backoff run away under flapping — the SDK is mid-sleep when later kills land and never observes them. 1s mirrors sdk-python's reset-on-every-successful-connect behavior. Sustained outages still back off exponentially (`mark_success` is never called, so the reset never triggers).
- **Fix (SSE): make `ReconnectCountingLogger` raise-proof (qfg-cf52).** ld-eventsource calls the logger from inside a bare-`Thread` `run_stream` loop with several call sites unguarded by `rescue`. A throwing wrapper would kill the worker with `@stopped=false`, leaving `closed?` false forever — silently wedging the SSE stream (the intermittent chaos scenario 05 flake). Every wrapper step is now independently rescued.

## 0.0.14 - 2026-05-10

- **Feat: expose `variant` and `flag_metadata` on `EvaluationDetails` (qfg-9dbl).** OpenFeature's `EvaluationDetails` Ruby return type now carries the variant name and the flag-level metadata hash alongside the resolved value/reason. Brings sdk-ruby to parity with the other SDKs' detail surfaces and lets host apps (incl. the Ruby OpenFeature provider) read variant/metadata without re-fetching the config.
- **Test: regenerate integration tests from rubocop-clean templates (qfg-vrck).** The integration suite under `test/integration/` is now generated from templates that pass `bundle exec rubocop` on first emit, so future regenerations don't trigger a follow-up autofix commit.

## 0.0.13 - 2026-05-07

- **Feat: `IS_PRESENT` and `IS_NOT_PRESENT` targeting operators (qfg-7jnb.6).** Both take only `propertyName` (no `valueToMatch`). `IS_PRESENT` resolves the dotted path against the merged context and returns true iff the value is non-nil. Type-agnostic — empty string `""`, `0`, and `false` all count as **present**; only `nil` / missing keys (including missing nested paths) are absent. `IS_NOT_PRESENT` is the negation. Implemented explicitly without ActiveSupport's `present?` / `blank?`, which would have given the wrong semantics on `""` and `false`. Matches sdk-node, sdk-go, sdk-python, sdk-ruby, sdk-javascript wire behaviour. Closes the integration-test parity gap that left 7 RSpec/Minitest cases red since the operators landed in `integration-test-data`.

## 0.0.12 - 2026-05-03

- **Feat: pluggable `logger:` kwarg on `Quonfig::Client.new`.** Host apps can now pass `Rails.logger` (or any stdlib `Logger`-compatible instance) and have all SDK warnings/errors flow through it instead of bare stderr / SemanticLogger. Implemented as a class-level `Quonfig::InternalLogger.user_logger` override that all `LOG` constants respect at log-call time, so existing per-class `LOG` constants pick it up automatically. Duck-typed (responds to `debug`/`info`/`warn`/`error`); missing levels degrade gracefully. SemanticLogger auto-detection is unchanged when no logger is supplied. Also routes the two outlier `dev_context.rb` warns (file read / JSON parse failures) through `InternalLogger` so they pick up the host-supplied logger too. (qfg-mol-1qw.3)

## 0.0.11 - 2026-05-02

- **Fix (telemetry): SSE clientName attribution.** The SSE client was sending
  `X-Quonfig-SDK-Version: sdk-ruby-<version>`, which the api-telemetry parser
  splits on the first dash, so it landed as `clientName="sdk"`,
  `clientVersion="ruby-<version>"`. Now sends `ruby-<version>` to match
  `http_connection.rb`, so both transports attribute consistently as
  `clientName="ruby"`.
- **Release plumbing: drop juwelier, tag-triggered publish.** The gem is now
  built from a hand-written `quonfig.gemspec` that reads the version from
  `Quonfig::VERSION` (in `lib/quonfig/version.rb`) and lists shipped files
  explicitly. The `release.yml` workflow now fires on `v*` tag pushes, not
  every successful main build, and refuses to publish unless the tag matches
  `Quonfig::VERSION`. Together these eliminate the gemspec-vs-VERSION drift
  that prevented the original 0.0.11 publish (gem built as 0.0.10 internally
  while filename said 0.0.11) and the manifest-drift bug from qfg-e588.

## 0.0.10 - 2026-05-01

- **BREAKING (env): `QUONFIG_TELEMETRY_URL` and `QUONFIG_API_URLS` env vars
  removed.** Replaced by a single `QUONFIG_DOMAIN` env var (default
  `quonfig.com`) that derives api, sse, and telemetry URLs uniformly. e.g.
  `QUONFIG_DOMAIN=quonfig-staging.com` → `https://primary.quonfig-staging.com`,
  `https://stream.primary.quonfig-staging.com`,
  `https://telemetry.quonfig-staging.com`. Mirrors the CLI's
  `domain-urls.ts` convention and matches sdk-go / sdk-node. Resolution order
  (highest wins): explicit `api_urls:` / `telemetry_url:` kwargs >
  `QUONFIG_DOMAIN` > hardcoded default. Fixes qfg-w6gg, where the prior
  primary-prefix regex silently fell through to prod telemetry on staging
  hosts. The new `Quonfig::Options#init` also accepts an explicit
  `telemetry_url:` kwarg (was previously documented but not wired up).
- **Default `api_urls` now includes secondary.** Was `[primary]`, now
  `[primary, secondary]` to match every other SDK and provide failover.
- **Release plumbing: pre-publish smoke check (qfg-e588).** The Rakefile
  `:release` task and the `release.yml` workflow now run
  `scripts/smoke_check.sh` after `gem build` and before `gem push`. The
  script installs the freshly built `.gem` into a sandbox `GEM_HOME` and
  shells out to `ruby -rquonfig -e 'puts Quonfig::VERSION'`. If the
  require fails or the version mismatches, the publish aborts. This is
  the prevention measure for qfg-e588, where 0.0.9 was published with a
  stale gemspec manifest missing `lib/quonfig/evaluation_details.rb` and
  every consumer hit `LoadError` at install time.

## 0.0.8 - 2026-04-26

- **Fix (gemspec): drop deleted `scripts/` entry from manifest** — regenerated
  juwelier gemspec so `gem build` no longer fails on the missing
  `scripts/generate_integration_tests.rb` file. Also untracked stray
  `.DS_Store`. v0.0.7 was tagged but never published due to this bug.

## 0.0.7 - 2026-04-26

- **New: `client.enabled?` / `client.default` / `client.client_construction` integration helpers** —
  Adds aggregator helpers used by the cross-SDK post + telemetry integration suites.
- **New: telemetry eval-summaries aggregator + `at_exit` drain (qfg-9x7)** —
  Periodically batches evaluation summaries and drains them on process exit so
  short-lived scripts still report telemetry.
- **New: context telemetry aggregators ported from sdk-node** — context shapes
  and example-contexts ship through the same aggregator path as sdk-node and
  sdk-go.
- **New errors: `DecryptionError`, `MissingEnvironmentError`,
  `InvalidEnvironmentError`** — explicit error classes raised from the resolver
  and datadir loaders.
- **Resolver: provided ENV_VAR resolution + coercion (qfg-08q)** — config values
  marked `provided` now resolve from the environment at evaluation time and are
  coerced to the declared value type.
- **Fix (resolver): raise on missing key, decode weighted/duration/decryption** —
  `get_or_raise` now raises `MissingDefaultError` for unknown keys, and weighted /
  duration / decryption value types decode correctly through the JSON resolver.
- **Fix (context): `grouped_key` drops anonymous contexts** — anonymous contexts
  are no longer mixed into the grouped-context key, matching sdk-node and sdk-go.

## 0.0.6 - 2026-04-22

- **New: `Quonfig::StdlibFormatter` + `client.stdlib_formatter(logger_name:)`** —
  Ruby's built-in `::Logger` now gets drop-in dynamic log-level gating,
  on par with the existing SemanticLogger integration. The client helper
  returns a Proc matching the stdlib `logger.formatter =` contract
  (`(severity, datetime, progname, msg) -> String`). For each log call
  the proc evaluates `should_log?(logger_path: logger_name || progname,
  desired_level: severity)` and either formats the record or returns an
  empty string (which `::Logger` writes as zero bytes, suppressing the
  line). `logger_name` flows into `quonfig-sdk-logging.key` verbatim —
  no normalization — so customer rules target exact class names.
  Raises `Quonfig::Error` if `logger_key` was not set at init. Parallels
  sdk-node's Winston formatter, sdk-python's `logging.Filter`, and
  sdk-go's `slog.Handler`. Closes Stage 2 of the per-SDK logger-path
  rollout.

## 0.0.5 - 2026-04-22

- **BREAKING — SemanticLoggerFilter context key renamed.** The filter
  previously exposed the logger name under
  `{ 'quonfig' => { 'logger-name' => '<normalized>' } }`. It now uses
  `{ 'quonfig-sdk-logging' => { 'key' => '<verbatim name>' } }` so that
  all SDKs (node, go, ruby, python) share one top-level context name.
  Any customer rules that match on the old `quonfig.logger-name` property
  must be rewritten to match `quonfig-sdk-logging.key`.
- **BREAKING — logger name normalization removed.** The filter no longer
  converts `MyApp::Services::Auth` → `my_app.services.auth`. Native Ruby
  class names are passed through verbatim. Rules should target the exact
  class name (e.g. `PROP_STARTS_WITH_ONE_OF "MyApp::Services::"`).
- **New: `logger_key` client option** (snake_case) — pass to
  `Quonfig::Options.new(logger_key: 'log-level.my-app')` or via
  `Quonfig.init`. Declares the Quonfig config key the higher-level
  `should_log?` helper evaluates for every log call.
- **New: `client.should_log?(logger_path:, desired_level:, contexts:)`** —
  Reforge-style convenience on top of `get`. Evaluates `logger_key` with
  `{ 'quonfig-sdk-logging' => { 'key' => logger_path } }` merged into the
  caller's contexts, then compares the returned level to `desired_level`.
  Raises `Quonfig::Error` if `logger_key` was not set at init. Parallels
  sdk-node's `shouldLog({loggerPath})` and sdk-go's `ShouldLogPath`.
- Stage 1 of the per-SDK logger-path rollout (after sdk-node 0.0.14 and
  sdk-go 0.0.10 shipped the same shape).

## 0.0.4 - 2026-04-22

- **Fix (P0 from test-ruby friction log):** Network mode is now wired through
  `Client`. Previously, `Quonfig.init` with just `QUONFIG_BACKEND_SDK_KEY`
  succeeded silently against an empty store; `get` and `enabled?` returned
  the default for every key because no HTTP fetch ever happened. Now:
  - On `Client#initialize` (when neither `datadir:` nor `store:` is passed)
    we do a synchronous HTTP GET against the first `api_urls[0]` (failing
    over to secondaries), bounded by `initialization_timeout_sec` (default
    10s). `on_init_failure` decides raise vs continue with empty store.
  - `enable_sse` (default `true`) subscribes to `{stream.*}/api/v2/sse/config`
    and applies incremental envelopes to the live `ConfigStore`.
  - `enable_polling` (default `true`) starts a background poller IFF SSE did
    not start successfully. This avoids double-fetching when SSE is healthy
    while still refreshing in proxied / SSE-blocked environments. Interval
    comes from `Options#poll_interval` (default 60s).
  - `Client#stop` now closes the SSE connection and kills the poll thread.
- Adds `Options#poll_interval` (default 60s); previously missing from the
  Options surface despite being documented.
- `ConfigLoader` now populates the `ConfigStore` directly on each successful
  fetch, so the Evaluator/Resolver see the new configs immediately (wire
  path matches sdk-node/sdk-go — `ConfigResponse` envelope JSON). (qfg-s7h)

## 0.0.3 - 2026-04-22

- **Release plumbing only** — no functional changes. Renames the release
  workflow from `push_gem.yml` to `release.yml` to match the Trusted
  Publisher record on rubygems.org, and restores the dynamic
  `s.version = File.read("VERSION")` pattern in the gemspec so future
  version bumps are a one-line VERSION edit (Juwelier's regen had
  hardcoded it). First publish via the automated trusted-publishing flow.

## 0.0.2 - 2026-04-22

- **Fix:** SSE client now connects to `/api/v2/sse/config` to match the server route and other Quonfig SDKs (was `/api/v2/sse`, which would have failed at runtime against api-delivery). (qfg-uq8)
- **Test cleanup:** removed two unused Prefab-era integration tests in `test_sse_config_client.rb` that targeted `goatsofreforge.com` and the dead `test/integration_test.rb` helper class. (qfg-9u6)

## 0.0.1 - 2026-04-21

- **Rename:** gem renamed from `sdk-reforge` to `quonfig`; top-level module `Reforge` → `Quonfig`. First release of the Quonfig Ruby SDK; version reset to `0.0.1` under the new gem name.
- **Env vars:** canonical names are now `QUONFIG_BACKEND_SDK_KEY`, `QUONFIG_DIR`, `QUONFIG_DATASOURCES`, `QUONFIG_API_URLS`. Legacy `REFORGE_*` / `PREFAB_*` env vars are no longer read.
- **BREAKING:** option `sources:` renamed to `api_urls:` (matches other Quonfig SDKs). No alias/deprecation — 0.0.x strategy. Env var `QUONFIG_SOURCES` renamed to `QUONFIG_API_URLS`.
- **BREAKING:** `DEFAULT_API_URLS` is now `['https://primary.quonfig.com']` (was `[primary, secondary]`). SSE stream URLs are derived by prepending `stream.` to each api_url hostname (see `Quonfig::Options.derive_stream_url`).
- **Requires:** `require 'sdk-reforge'` → `require 'quonfig'`.

## 1.12.0 - 2025-10-31

- Restore log level functionality with LOG_LEVEL_V2 support
- Make SemanticLogger optional - SDK now works with or without it
- Add stdlib Logger support as alternative to SemanticLogger
- Add InternalLogger that automatically uses SemanticLogger or stdlib Logger
- Add `logger_key` initialization option for configuring dynamic log levels
- Add `stdlib_formatter` method for stdlib Logger integration

## 1.11.2 - 2025-10-07

- Address OpenSSL issue with vulnerability to truncation attack

## 1.11.1 - 2025-10-06

- quiet logging for SSE reconnections
- let the SSE::Client handle the Last-Event-ID header

## 1.10.0 - 2025-10-02

- require `base64` for newest ruby versions
- look for `REFORGE_BACKEND_SDK_KEY` and `REFORGE_DATAFILE`

## 1.9.2 - 2025-10-02

- Fix bug in row index calculation for the evaluation summary data

## 1.9.1 - 2025-10-01

- Fix entrypoint


## 1.9.0 - 2025-08-23

- Moved to reforge gem name `sdk-reforge`
- Add automated gem publishing via GitHub Actions trusted publishing
- Add support for `reforge.current-time` virtual context
- Dropped the previous implementation of dynamic logging support
- Removed local file loading based on prefab-envs

## 1.8.9 - 2025-04-15

- Fix support for virtual context `prefab.current-time` [#229]

## 1.8.8 - 2025-02-28

- Add conditional fetch support for configurations [#226]
- Operator support for string starts with, contains [#212]
- Operator support for regex, semver (protobuf update) [#215]
- Operator support for date comparison (before/after) [#221]
- Operator support for numeric comparisons [#220]


## 1.8.7 - 2024-10-25

- Add option symbolize_json_names [#211]


## 1.8.6 - 2024-10-07

- Fix deprecation warning caused by x_datafile being set by default [#208]

## 1.8.5 - 2024-09-27

- Fix JS bootstrapping and improve performance [#206]
- Promote `datafile` from `x_datafile` [#205]

## 1.8.4 - 2024-09-19

- Use `stream` subdomain for SSE [#203]

## 1.8.3 - 2024-09-16

- Add JavaScript stub & bootstrapping [#200]

## 1.8.2 - 2024-09-03

- Forbid bad semantic_logger version [#198]

## 1.8.1 - 2024-09-03

- Fix SSE reconnection bug [#197]

## 1.8.0 - 2024-08-22

- Load config from belt and failover to suspenders [#195]

## 1.7.2 - 2024-06-24

- Support JSON config values [#194]

## 1.7.1 - 2024-04-11

- Ergonomics [#191]

## 1.7.0 - 2024-04-10

- Add duration support [#187]

## 1.6.2 - 2024-03-29

- Fix context telemetry when JIT and Block contexts are combined [#185]
- Remove logger prefix [#186]

## 1.6.1 - 2024-03-28

- Performance optimizations [#178]
- Global context [#182]

## 1.6.0 - 2024-03-27

- Use semantic_logger for internal logging [#173]
- Remove Prefab::LoggerClient as a logger for end users [#173]
- Provide log_filter for end users [#173]

## 1.5.1 - 2024-02-22

- Fix: Send context shapes by default [#174]

## 1.5.0 - 2024-02-12

- Fix potential inconsistent Context behavior [#172]

## 1.4.5 - 2024-01-31

- Refactor out a `should_log?` method [#170]

## 1.4.4 - 2024-01-26

- Raise when ENV var is missing

## 1.4.3 - 2024-01-17

- Updated proto definition file

## 1.4.2 - 2023-12-14

- Use reportable value even for invalid data [#166]

## 1.4.1 - 2023-12-08

- Include version in `get` request [#165]

## 1.4.0 - 2023-11-28

- ActiveJob tagged logger issue [#164]
- Compact Log Format [#163]
- Tagged Logging [#161]
- ContextKey logging thread safety [#162]

## 1.3.2 - 2023-11-15

- Send back cloud.prefab logging telemetry [#160]

## 1.3.1 - 2023-11-14

- Improve path of rails.controller logging & fix strong param include [#159]

## 1.3.0 - 2023-11-13

- Less logging when wifi is off and we load from cache [#157]
- Alpha: Add Provided & Secret Support [#152]
- Alpha: x_datafile [#156]
- Add single line action-controller output under rails.controller [#158]

## 1.2.1 - 2023-11-01

- Update protobuf definitions [#154]

## 1.2.0 - 2023-10-30

- Add `Prefab.get('key')` style usage after a `Prefab.init()` call [#151]
- Add `add_context_keys` and `with_context_keys` method for LoggerClient [#145]

## 1.1.2 - 2023-10-13

- Add `cloud.prefab.client.criteria_evaluator` `debug` logging of evaluations [#150]
- Add `x_use_local_cache` for local caching [#148]
- Tests run in RubyMine [#147]

## 1.1.1 - 2023-10-11

- Migrate happy-path client-initialization logging to `DEBUG` level rather than `INFO` [#144]
- Add `ConfigClientPresenter` for logging out stats upon successful client initialization [#144]
- Add support for default context [#146]

## 1.1.0 - 2023-09-18

- Add support for structured logging [#143]
  - Ability to pass a hash of key/value context pairs to any of the user-facing log methods

## 1.0.1 - 2023-08-17

- Bug fix for StringList w/ ExampleContextsAggregator [#141]

## 1.0.0 - 2023-08-10

- Removed EvaluatedKeysAggregator [#137]
- Change `collect_evaluation_summaries` default to true [#136]
- Removed some backwards compatibility shims [#133]
- Standardizing options [#132]
  - Note that the default value for `context_upload_mode` is `:periodic_example` which means example contexts will be collected.
    This enables easy variant override assignment in our UI. More at https://prefab.cloud/blog/feature-flag-variant-assignment/

## 0.24.6 - 2023-07-31

- Logger Client compatibility [#129]
- Replace EvaluatedConfigs with ExampleContexts [#128]
- Add ConfigEvaluationSummaries (opt-in for now) [#123]

## 0.24.5 - 2023-07-10

- Report Client Version [#121]

## [0.24.4] - 2023-07-06

- Support Timed Loggers [#119]
- Added EvaluatedConfigsAggregator (disabled by default) [#118]
- Added EvaluatedKeysAggregator (disabled by default) [#117]
- Dropped Ruby 2.6 support [#116]
- Capture/report context shapes [#115]
- Added bin/console [#114]

## [0.24.3] - 2023-05-15

- Add JSON log formatter [#106]

# [0.24.2] - 2023-05-12

- Fix bug in FF rollout eval consistency [#108]
- Simplify forking [#107]

# [0.24.1] - 2023-04-26

- Fix misleading deprecation warning [#105]

# [0.24.0] - 2023-04-26

- Backwards compatibility for JIT context [#104]
- Remove upsert [#103]
- Add resolver presenter and `on_update` callback [#102]
- Deprecate `lookup_key` and introduce Context [#99]

# [0.23.8] - 2023-04-21

- Update protobuf [#101]

# [0.23.7] - 2023-04-21

- Guard against ActiveJob not being loaded [#100]

# [0.23.6] - 2023-04-17

- Fix bug in FF rollout eval consistency [#98]
- Add tests for block-form of logging [#96]

# [0.23.5] - 2023-04-13

- Cast the value to string when checking presence in string list [#95]

# [0.23.4] - 2023-04-12

- Remove GRPC [#93]

# [0.23.3] - 2023-04-07

- Use exponential backoff for log level uploading [#92]

# [0.23.2] - 2023-04-04

- Move log collection logs from INFO to DEBUG [#91]
- Fix: Handle trailing slash in PREFAB_API_URL [#90]

# [0.23.1] - 2023-03-30

- ActiveStorage not defined in Rails < 5.2 [#87]

# [0.23.0] - 2023-03-28

- Convenience for setting Rails.logger [#85]
- Log evaluation according to rules [#81]

# [0.22.0] - 2023-03-15

- Report log paths and usages [#79]
- Accept hash or keyword args in `initialize` [#78]
