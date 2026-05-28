# quonfig

Ruby SDK for [Quonfig](https://quonfig.com) — Feature Flags, Live Config, and Dynamic Log Levels.

> **Note:** This SDK is pre-1.0 and the API is not yet stable.

## Installation

Add the gem to your Gemfile:

```ruby
gem 'quonfig'
```

Or install directly:

```bash
gem install quonfig
```

## Quickstart

```ruby
require 'quonfig'

client = Quonfig::Client.new(sdk_key: ENV['QUONFIG_BACKEND_SDK_KEY'])

# Feature flags
if client.enabled?('new-dashboard')
  # show new dashboard
end

# Typed config values
limit   = client.get_int('rate-limit')
name    = client.get_string('app.display-name')
regions = client.get_string_list('allowed-regions')

# Context-aware evaluation — pass a context hash as the last argument
value = client.get_string('homepage-hero', user: { key: 'user-123', country: 'US' })
```

## Context

Contexts are hashes grouped by scope (`user`, `team`, `device`, etc.). You can
attach a context in three ways:

### 1. Per-call context

```ruby
client.get_bool('beta-feature', user: { key: 'user-123', plan: 'pro' })
```

### 2. `in_context` block

Everything evaluated inside the block sees the supplied context. The block's
return value is returned from `in_context`.

```ruby
result = client.in_context(user: { key: 'user-123', plan: 'pro' }) do |bound|
  {
    hero:   bound.get_string('homepage-hero'),
    limit:  bound.get_int('rate-limit'),
    beta?:  bound.enabled?('beta-feature')
  }
end
```

### 3. `with_context` — BoundClient for repeated lookups

`with_context` returns an immutable `BoundClient` that carries the context on
every call. Useful when you want to pass a context-bound handle down the stack.

```ruby
bound = client.with_context(user: { key: 'user-123', plan: 'pro' })

bound.get_string('homepage-hero')
bound.enabled?('beta-feature')
bound.get_int('rate-limit')
```

## Datadir / offline mode

For tests, CI, or air-gapped environments, point the client at a local workspace
directory instead of the Quonfig API. In datadir mode the SDK loads JSON config
files from disk and performs no network I/O.

```ruby
client = Quonfig::Client.new(
  datadir:     '/path/to/workspace',
  environment: 'production'
)

client.get_bool('feature-x')
```

You can also set `QUONFIG_DIR` in the environment and omit the `datadir:`
option; when `QUONFIG_DIR` is set the SDK switches to datadir mode
automatically. `environment` is required in datadir mode — it can be provided
via the option or via `QUONFIG_ENVIRONMENT`.

```bash
export QUONFIG_DIR=/path/to/workspace
export QUONFIG_ENVIRONMENT=production
```

```ruby
client = Quonfig::Client.new  # reads QUONFIG_DIR + QUONFIG_ENVIRONMENT
```

## Datadir mode: auto-reload on file changes

In datadir mode the SDK loads the workspace once at construction time and then
serves config purely from memory. Opt in to `data_dir_auto_reload: true` to
have the SDK watch the directory and re-read the envelope whenever files
change — an editor save, a `git pull`, or a build step that rewrites the
workspace.

```ruby
client = Quonfig::Client.new(
  datadir:              '/path/to/workspace',
  environment:          'development',
  data_dir_auto_reload: true # off by default — must be opted in
)

client.on_update do
  puts 'Quonfig configs reloaded from disk'
end

# Edit a file under /path/to/workspace and on_update fires within ~200ms.

# On shutdown, stop stops the watcher and cancels any pending debounce.
client.stop
```

### When to enable

- Local development with the datadir checked out from git.
- Self-hosted servers that `git pull` the datadir on a schedule.
- CI jobs that mutate the datadir between assertions.

### When NOT to enable

- **Read-only / immutable filesystems** (some containers, scratch images,
  AWS Lambda). Watch registration may fail; the SDK degrades gracefully
  (logs the error and continues serving the envelope it loaded at init time)
  but you're paying for nothing.
- **Build-time-embedded workflows** where the datadir is bundled into the
  artifact and never changes at runtime. Watching wastes a thread and a
  native-backend handle.
- **Production paths where reload timing matters** — e.g. you'd rather pin
  the envelope you shipped with and roll forward through a redeploy than
  have it shift under traffic.

Default is `false`; datadir mode is silent until you opt in.

### Behavior contract

- **Parse-then-swap.** If the new envelope fails to parse (truncated write,
  mid-`git pull` state, invalid JSON), the SDK logs the error and **keeps
  serving the previous envelope**. `on_update` is _not_ fired on parse
  failure — only on a successful swap.
- **Debounced.** Bursts of filesystem events (atomic-rename editor saves,
  `git pull` touching dozens of files) coalesce into a single re-read.
  Default window: **200ms** — long enough to absorb the 3–5 events a typical
  editor emits in <50ms, short enough that interactive edits feel immediate.
  Tune via `data_dir_auto_reload_debounce_ms` if you need a different
  window.
- **Graceful degrade.** If watch registration fails (read-only fs, immutable
  container, missing native backend), the SDK logs and continues without
  watching — it does **not** raise from the constructor.
- **Symlinks.** The watcher resolves `datadir` to its real path at start
  time. Editing the file the symlink points at _is_ detected; atomic flips
  that retarget the link itself are **not**.
- **Shutdown.** `client.stop` stops the watcher and cancels any pending
  debounce. There is no separate handle to manage — the watcher lifecycle
  is tied to the client.

### Fork safety (Puma cluster, Unicorn, Resque, Sidekiq)

The auto-reload watcher uses a background thread, which — like any Ruby
thread — does not survive `fork(2)`. **You do not need to wire this up
manually on Ruby 3.1+.** The SDK's `Process._fork` hook (see [Rails
integration](#rails-integration) below) stops the watcher in the parent
before fork and restarts a fresh watcher in each child after fork. This
covers Puma clustered mode, Unicorn, Sidekiq's parent-forks-workers model,
Resque, Spring, and manual `fork { ... }` calls.

On Ruby 3.0 (no `Process._fork`), follow the manual `before_fork` /
`on_worker_boot` pattern in the [Rails integration](#rails-integration)
section — `Quonfig.fork` rebuilds the full client, including the datadir
watcher, in the child.

### Tuning the debounce window

```ruby
Quonfig::Client.new(
  datadir:                          '/path/to/workspace',
  data_dir_auto_reload:             true,
  data_dir_auto_reload_debounce_ms: 1000 # wait a full second after the last event
)
```

The default (200 ms) is tuned for interactive editing. Raise it if you have
a noisy producer (continuously regenerating files) and you'd rather see one
reload per second than per save. Lower it only if you've measured that 200 ms
is meaningfully too slow for your use case.

See the [open-source / local how-to](https://docs.quonfig.com/docs/how-tos/open-source-local)
for the cross-SDK story (sdk-node, sdk-go, sdk-ruby, sdk-python, sdk-java).

## Environment variables

| Variable                    | Purpose                                                                                  |
|-----------------------------|------------------------------------------------------------------------------------------|
| `QUONFIG_BACKEND_SDK_KEY`   | SDK key used to authenticate against the Quonfig API. Used when `sdk_key:` is omitted.   |
| `QUONFIG_DIR`               | Path to a workspace directory. When set, the SDK runs in datadir/offline mode.           |
| `QUONFIG_ENVIRONMENT`       | Environment name (`production`, `staging`, `development`) evaluated in datadir mode.     |
| `QUONFIG_DOMAIN`            | Base domain used to derive api, sse, and telemetry URLs. Defaults to `quonfig.com`. Set to `quonfig-staging.com` to point at staging. Explicit `api_urls:` / `telemetry_url:` kwargs override this. |

## Constructor options

```ruby
Quonfig::Client.new(
  sdk_key:                   '...',                          # required unless QUONFIG_BACKEND_SDK_KEY is set
  api_urls:                  ['https://primary.quonfig.com', 'https://secondary.quonfig.com'],
  telemetry_url:             'https://telemetry.quonfig.com',
  enable_sse:                true,
  fallback_poll_enabled:     true,
  fallback_poll_interval_ms: 60_000,
  init_timeout:              10,
  on_no_default:             :error,
  global_context:            {},
  datadir:                   '/path/to/workspace',
  environment:               'production',
  data_dir_auto_reload:             false,
  data_dir_auto_reload_debounce_ms: 200
)
```

| Option            | Type                       | Default                                                             | Description                                                                                       |
|-------------------|----------------------------|---------------------------------------------------------------------|---------------------------------------------------------------------------------------------------|
| `sdk_key`         | `String`                   | `ENV['QUONFIG_BACKEND_SDK_KEY']`                                    | SDK key for API authentication.                                                                   |
| `api_urls`        | `Array<String>`            | `["https://primary.${QUONFIG_DOMAIN}", "https://secondary.${QUONFIG_DOMAIN}"]` | Ordered list of API base URLs to try. SSE stream URLs are derived by prepending `stream.` to each hostname. Defaults derive from `QUONFIG_DOMAIN` (default `quonfig.com`). |
| `telemetry_url`   | `String`                   | `https://telemetry.${QUONFIG_DOMAIN}`                                          | Base URL for the telemetry service. Default derives from `QUONFIG_DOMAIN`.                        |
| `enable_sse`              | `Boolean`                  | `true`                                                              | Receive real-time updates over Server-Sent Events.                                                |
| `fallback_poll_enabled`   | `Boolean`                  | `true`                                                              | Engage HTTP polling as a fallback when SSE is unavailable for >= 2x `fallback_poll_interval_ms`. Deprecated alias: `enable_polling`. |
| `fallback_poll_interval_ms` | `Integer` (ms)           | `60_000`                                                            | Interval between fallback HTTP polls, in milliseconds. Deprecated alias: `poll_interval` (seconds, multiplied by 1000 internally). |
| `init_timeout`    | `Integer` (seconds)        | `10`                                                                | Maximum time to wait for the initial config load.                                                 |
| `on_no_default`   | `Symbol`                   | `:error`                                                            | Behavior when a key has no value and no default: `:error`, `:warn`, or `:ignore`.                 |
| `global_context`  | `Hash`                     | `{}`                                                                | Context applied to every evaluation.                                                              |
| `datadir`         | `String`                   | `ENV['QUONFIG_DIR']`                                                | Path to a local workspace. When set, the SDK runs offline from disk.                              |
| `environment`     | `String`                   | `ENV['QUONFIG_ENVIRONMENT']`                                        | Environment to evaluate in datadir mode. Required when `datadir` is set.                          |
| `data_dir_auto_reload`              | `Boolean`         | `false`                                                             | Datadir mode only. When `true`, the SDK watches the datadir and re-reads the envelope when files change. See [Datadir mode: auto-reload on file changes](#datadir-mode-auto-reload-on-file-changes). |
| `data_dir_auto_reload_debounce_ms`  | `Integer` (ms)    | `200`                                                               | Debounce window for the auto-reload watcher — events arriving inside the window are coalesced into a single re-read. Ignored when `data_dir_auto_reload` is `false`. |
| `logger`          | Logger-like object         | `nil`                                                               | Optional host-app logger (e.g. `Rails.logger`). Must respond to `debug`/`info`/`warn`/`error`. When set, all SDK warnings/errors flow through this logger instead of the default stderr / SemanticLogger backend. |

## Typed getters

Each typed getter takes a config key and an optional context hash. If the key
is missing or the stored value does not match the requested type, the getter
returns `nil`.

| Method                                          | Returns                       |
|-------------------------------------------------|-------------------------------|
| `get_string(key, contexts = nil)`               | `String` or `nil`             |
| `get_int(key, contexts = nil)`                  | `Integer` or `nil`            |
| `get_float(key, contexts = nil)`                | `Float` or `nil`              |
| `get_bool(key, contexts = nil)`                 | `true`, `false`, or `nil`     |
| `get_string_list(key, contexts = nil)`          | `Array<String>` or `nil`      |
| `get_duration(key, contexts = nil)`             | `Float` (seconds) or `nil`    |
| `get_json(key, contexts = nil)`                 | `Hash`, `Array`, or `nil`     |
| `enabled?(feature_name, contexts = nil)`        | `true` or `false`             |

Example:

```ruby
client.get_string('app.display-name')
client.get_int('rate-limit', user: { key: 'user-123' })
client.get_float('pricing.multiplier')
client.get_bool('flags.new-checkout')
client.get_string_list('allowed-regions')
client.get_duration('request-timeout')
client.get_json('homepage.layout')
client.enabled?('beta-feature', user: { key: 'user-123' })
```

## Dynamic log levels (SemanticLogger)

Quonfig can drive per-class log levels at runtime. Set config keys like
`log-levels.my_app.foo.bar` to one of `trace`, `debug`, `info`, `warn`, `error`,
`fatal` and wire the filter into SemanticLogger:

```ruby
require 'quonfig'
require 'semantic_logger'

client = Quonfig::Client.new(sdk_key: ENV['QUONFIG_BACKEND_SDK_KEY'])
SemanticLogger.add_appender(io: $stdout, filter: client.semantic_logger_filter)
```

Lookup is exact-match only: logger name `MyApp::Foo::Bar` normalizes to
`log-levels.my_app.foo.bar`. If no key is set the log is allowed through and
SemanticLogger's static level decides. There is no hierarchy walk — a value on
`log-levels.my_app` does not affect `log-levels.my_app.foo.bar`.

Pass `key_prefix:` to use a prefix other than `log-levels.`:

```ruby
client.semantic_logger_filter(key_prefix: 'debug.')
```

## Dynamic log levels with stdlib Logger

If you use Ruby's built-in `::Logger` instead of SemanticLogger, wire the
formatter returned by `client.stdlib_formatter` into your logger:

```ruby
require 'quonfig'
require 'logger'

client = Quonfig::Client.new(
  sdk_key:    ENV['QUONFIG_BACKEND_SDK_KEY'],
  logger_key: 'log-level.my-app'
)

logger = ::Logger.new($stdout)
logger.level = ::Logger::DEBUG
logger.formatter = client.stdlib_formatter(logger_name: 'MyApp::Services::Auth')
```

The formatter asks the client `should_log?(logger_path:, desired_level:)`
for every call; lines below the configured level return an empty string
(which `::Logger` writes as zero bytes, suppressing the line). `logger_name`
is passed to Quonfig verbatim under `quonfig-sdk-logging.key` so a single
`log-level.my-app` config can drive per-class overrides via rules like
`PROP_STARTS_WITH_ONE_OF "MyApp::Services::"`.

Omit `logger_name:` to have the formatter fall through to the Logger's
`progname` at call time:

```ruby
logger.formatter = client.stdlib_formatter
logger.progname  = 'MyApp::Services::Auth'
```

If both are supplied, the explicit `logger_name:` wins.

## Rails integration

The SDK runs a background SSE thread (and optional polling thread) that you do
not want to inherit across a `fork(2)`. Forked threads in the child process
are dead — the SSE socket is held open by a thread that no longer exists, and
the child silently stops receiving live updates.

**On Ruby 3.1+ the SDK installs a `Process._fork` hook at load time** that
automatically tears down threaded components in the parent and restarts them
in the child. This covers any `Process.fork` / `Kernel#fork` path — Puma's
clustered mode, Unicorn, Sidekiq's parent-forks-workers model, Spring, and
manual `fork { ... }` calls. **No customer wiring is required.**

Caveats:

- Ruby 3.0 has no hookable choke point — fall back to manual wiring (below).
- `system("fork-and-exec ...")` and `Process.spawn` are not covered (they do
  not go through `Process._fork`), but those execute a new program, so the
  in-process SSE state is moot.
- The hook tears down the SSE/polling/telemetry threads in the parent before
  fork (so the child does not inherit a live socket fd) and does **not**
  auto-restart the parent. This mirrors the Puma master case: the master no
  longer serves requests, so it does not need a live SSE connection. If you
  have a non-Puma topology where the parent must keep streaming after fork,
  call `Quonfig.instance.after_fork_in_child` manually in the parent after
  the fork returns.

### Puma (clustered mode)

With the automatic fork hook, the typical Puma config needs **no Quonfig
lifecycle wiring** — initialize in your Rails initializer and let the hook
handle the rest:

```ruby
# config/initializers/quonfig.rb
Quonfig.init(Quonfig::Options.new(sdk_key: ENV.fetch('QUONFIG_BACKEND_SDK_KEY')))
```

If you're on Ruby 3.0 (no `Process._fork`), wire the legacy hooks manually:

```ruby
# config/puma.rb (Ruby 3.0 only)
before_fork do
  Quonfig.instance.stop          # close the master's SSE before forking
end

on_worker_boot do
  Quonfig.fork                   # rebuild a fresh client per worker
end
```

### Sidekiq

On Ruby 3.1+ the automatic fork hook covers Sidekiq workers too — no
`configure_server` wiring required.

On Ruby 3.0:

```ruby
# config/initializers/quonfig.rb
Quonfig.init(Quonfig::Options.new(sdk_key: ENV.fetch('QUONFIG_BACKEND_SDK_KEY')))

# config/initializers/sidekiq.rb (Ruby 3.0 only)
Sidekiq.configure_server do |config|
  config.on(:startup)  { Quonfig.fork if Process.ppid != 1 }
  config.on(:shutdown) { Quonfig.instance.stop rescue nil }
end
```

For Sidekiq web/CLI processes that don't fork (default `concurrency: 1`),
`Quonfig.init` in the initializer is sufficient on any Ruby version.

### Spring / Bootsnap preloaders

Spring forks the preloader for each command. If your initializer creates a
Quonfig client at boot, the SSE thread will be inherited dead in every child.
Two options:

1. **Recommended:** initialize lazily — wrap `Quonfig.init` so it only runs
   the first time `Quonfig.instance` is called from a non-preloader process.
2. **Or:** call `Quonfig.fork` from a `Spring.after_fork` hook.

```ruby
# config/spring.rb
Spring.after_fork do
  Quonfig.fork if defined?(Quonfig) && Quonfig.instance_variable_get(:@singleton)
end
```

### Code reloading (Zeitwerk, development mode)

`Quonfig::Client` is a long-lived object — keep it out of `app/` (where
Zeitwerk reloads classes on every request) and pin it to a constant set in a
Rails initializer. The client itself is reload-safe because it does not
reference any application classes; the failure mode to avoid is *creating a
new client per request*, which leaks SSE threads and quickly exhausts file
descriptors.

```ruby
# config/initializers/quonfig.rb
# Quonfig.init is idempotent — a second call warns and returns the existing
# singleton — so it's safe to wrap in to_prepare for reload-friendliness.
Rails.application.config.to_prepare do
  Quonfig.init(Quonfig::Options.new(sdk_key: ENV.fetch('QUONFIG_BACKEND_SDK_KEY')))
end
```

## Thread safety

`Quonfig::Client` is safe to share across threads. Reads (`get`, `enabled?`,
`get_*`) and SSE-driven writes to the underlying `ConfigStore` use
`Concurrent::Map` for per-key atomicity. Eventual consistency across an
envelope is intentional: a reader concurrent with envelope application may
observe the new value for some keys and the old value for others, then
converge once the envelope finishes applying.

`Quonfig.fork` is the only safe way to "carry" a client across `Process.fork`
— do not reuse the parent's client in a child process.

## Diagnostic health signals

`Quonfig::Client` exposes two read-only getters for monitoring SDK liveness:

- `client.last_successful_refresh` — a `Time` (UTC) marking the most recent
  envelope install (any source: datadir, initial HTTP fetch, SSE, or fallback
  polling). Returns `nil` before the first install. Preserved across `stop`.
- `client.connection_state` — a `Symbol` describing the aggregate state:
  `:initializing`, `:connected`, `:disconnected`, or `:falling_back`.

> Do not wire `last_successful_refresh` or `connection_state` directly into a Kubernetes liveness probe. These signals are diagnostic, not pass/fail. A liveness probe based on SDK freshness will amplify transient network blips into restart cascades.

Compose your own threshold from the two getters if you need a dashboard signal
— but route alerts through a metrics pipeline, not a probe that restarts the
process.

There is intentionally no `client.healthy?` primitive.

## Documentation

Full documentation, including SPEC, SDK reference, and operational guides, is
available at [https://quonfig.com/docs](https://quonfig.com/docs).

## License

MIT
