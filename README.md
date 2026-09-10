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

### 2. `with_context` block

Everything evaluated inside the block sees the supplied context. The block's
return value is returned from `with_context`.

```ruby
result = client.with_context(user: { key: 'user-123', plan: 'pro' }) do |bound|
  {
    hero:   bound.get_string('homepage-hero'),
    limit:  bound.get_int('rate-limit'),
    beta?:  bound.enabled?('beta-feature')
  }
end
```

### 3. `with_context` — BoundClient for repeated lookups

Called without a block, `with_context` returns an immutable `BoundClient` that
carries the context on every call. Useful when you want to pass a
context-bound handle down the stack.

```ruby
bound = client.with_context(user: { key: 'user-123', plan: 'pro' })

bound.get_string('homepage-hero')
bound.enabled?('beta-feature')
bound.get_int('rate-limit')
```

> `in_context` is a deprecated alias of `with_context` kept for backward
> compatibility through 1.0.0. New code should use `with_context`.

## Datadir / offline mode

For tests, CI, or air-gapped environments, point the client at a local workspace
directory instead of the Quonfig API. In datadir mode the SDK loads JSON config
files from disk — config delivery does no network I/O at all: no config fetch,
no SSE stream, no polling.

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

### Telemetry in datadir mode

Usage telemetry is gated on **SDK-key presence, not on mode**. A datadir client
with an `sdk_key:` configured still reports evaluation summaries and context
telemetry to the telemetry service, exactly as a delivery-mode client does —
that combination is what makes flag usage visible in the Quonfig UI for services
that read config from a checked-out workspace.

A datadir client with **no** SDK key has no workspace to attribute telemetry to,
so it collects and sends nothing: fully offline, zero network I/O.

To run with a key but without telemetry, use the standard opt-outs:

```ruby
client = Quonfig::Client.new(
  datadir:                      '/path/to/workspace',
  environment:                  'production',
  sdk_key:                      ENV['QUONFIG_BACKEND_SDK_KEY'],
  collect_evaluation_summaries: false,
  context_upload_mode:          :none
)
```

> Changed in 1.3.0: before 1.3.0 a datadir sent nothing even with a valid SDK
> key. See the CHANGELOG.

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
manually on Ruby 3.1+.** After a fork, the child re-loads the workspace from
disk and registers a fresh watcher on its first use of the client (see [Rails
integration](#rails-integration) below); a child that never uses the client
starts no watcher at all. The parent's watcher is left alone and keeps
working. This covers Puma clustered mode, Unicorn, Resque, Spring, and manual
`fork { ... }` calls — including a `fork` inside a Sidekiq job.

On Ruby 3.0 (no `Process._fork`), follow the manual `on_worker_boot` pattern
in the [Rails integration](#rails-integration) section — `Quonfig.fork`
rebuilds the full client, including the datadir watcher, in the child.

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
  init_timeout_ms:           10_000,
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
| `init_timeout_ms` | `Integer` (ms)             | `10_000`                                                            | Maximum time to wait for the initial config load, in milliseconds. Deprecated alias: `initialization_timeout_sec` (seconds, multiplied by 1000 internally). |
| `on_no_default`   | `Symbol`                   | `:error`                                                            | Behavior when a key has no value and no default: `:error`, `:warn`, or `:ignore`.                 |
| `global_context`  | `Hash`                     | `{}`                                                                | Context applied to every evaluation.                                                              |
| `datadir`         | `String`                   | `ENV['QUONFIG_DIR']`                                                | Path to a local workspace. When set, the SDK runs offline from disk.                              |
| `environment`     | `String`                   | `ENV['QUONFIG_ENVIRONMENT']`                                        | Environment to evaluate in datadir mode. Required when `datadir` is set.                          |
| `data_dir_auto_reload`              | `Boolean`         | `false`                                                             | Datadir mode only. When `true`, the SDK watches the datadir and re-reads the envelope when files change. See [Datadir mode: auto-reload on file changes](#datadir-mode-auto-reload-on-file-changes). |
| `data_dir_auto_reload_debounce_ms`  | `Integer` (ms)    | `200`                                                               | Debounce window for the auto-reload watcher — events arriving inside the window are coalesced into a single re-read. Ignored when `data_dir_auto_reload` is `false`. |
| `logger`          | Logger-like object         | `nil`                                                               | Optional host-app logger (e.g. `Rails.logger`). Must respond to `debug`/`info`/`warn`/`error`. When set, all SDK warnings/errors flow through this logger instead of the default stderr / SemanticLogger backend. |

## Failover & `QUONFIG_DOMAIN`

By default the SDK derives every hostname from `QUONFIG_DOMAIN` (default
`quonfig.com`):

| Role                     | URL                                     |
|--------------------------|-----------------------------------------|
| Config fetch (primary)   | `https://primary.quonfig.com`           |
| SSE stream (primary)     | `https://stream.primary.quonfig.com`    |
| Config fetch (secondary) | `https://secondary.quonfig.com`         |
| SSE stream (secondary)   | `https://stream.secondary.quonfig.com`  |
| Telemetry                | `https://telemetry.quonfig.com`         |

Set `QUONFIG_DOMAIN` to move all of them together (e.g.
`QUONFIG_DOMAIN=quonfig-staging.com`). **Automatic failover and hedging between
the primary and the secondary are on by default** — the secondary runs on
separate infrastructure, and the HTTP config-fetch fails over to it if the
primary is unreachable and hedges to it if the primary is slow.

`api_urls:` replaces the derived list wholesale. To keep automatic failover
with custom URLs, **pass both a primary and a secondary URL**:

```ruby
Quonfig::Client.new(
  sdk_key: 'your-sdk-key',
  api_urls: [
    'https://primary.your-proxy.example',
    'https://secondary.your-proxy.example'
  ]
)
```

A single URL disables failover, and the SDK logs a warning at init. See
https://docs.quonfig.com/docs/explanations/architecture/resiliency for the full
model.

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

The SDK runs a background SSE thread (and optional polling thread). Ruby
threads do not survive `fork(2)`, so a child process inherits references to
threads that no longer exist and silently stops receiving live updates.

**On Ruby 3.1+ the SDK installs a `Process._fork` hook at load time** that
handles this for you. It covers any `Process.fork` / `Kernel#fork` path —
Puma's clustered mode, Unicorn, Spring, Resque, a `fork { ... }` inside a
Sidekiq job, and the `parallel` gem. **No customer wiring is required.**

**The hook is child-only. A fork never touches the process that forked.**
The parent keeps its SSE stream, its poller, its telemetry reporter, and its
live config straight through any number of forks — so a long-lived process
that forks workers *and keeps evaluating* (a Sidekiq process using the
`parallel` gem, a rake task that calls `fork`) stays current.
In the child, the SDK drops the inherited references without touching the
objects — it never closes the inherited socket, because `fork(2)` duplicates
the file descriptor and closing the child's copy of a TLS connection would
tear down the stream the **parent** is still using.

> **Upgrading from 1.3.0 or earlier:** if you added a manual
> `Quonfig.instance.after_fork_in_child` call **in the parent** as a
> workaround for the parent going dark, remove it. As of 1.4.0 that call is a
> no-op in the process that owns the client — the SDK decides that by
> comparing the current pid against the one it stamped when the client was
> built, so it is exact whether or not the parent has any threads running. It
> will not hurt you, but it is no longer doing anything, and the parent needs
> no call.

**After a fork, the child re-initializes on its first use of the client,
exactly like a newly constructed client — including its `on_init_failure`
policy: it fetches its own config and starts its own threads. It does not
evaluate from the parent's snapshot.** The hook itself does no I/O — it drops
what the child inherited and arms the re-initialization. So the first call in
a forked child pays one fetch, and a child that never uses the client costs
nothing: no fetch, no stream, no thread, no telemetry.

Caveats:

- Ruby 3.0 has no hookable choke point — fall back to manual wiring (below).
- `system("fork-and-exec ...")` and `Process.spawn` are not covered (they do
  not go through `Process._fork`), but those execute a new program, so the
  in-process SSE state is moot.
- The first lookup in a forked child **blocks** on that child's own config
  fetch, under the same `init_timeout_ms` and `on_init_failure` options a
  fresh client uses. With the default `on_init_failure: :return` a failed
  fetch logs one line and the child serves defaults until its stream or
  poller lands the first envelope. With `on_init_failure: :raise` the failure
  **raises out of that first lookup**, exactly as `Client.new` would, and
  later lookups keep raising — without re-fetching — until the update channel
  lands an envelope, at which point the client serves config normally again.
- **Other threads wait.** Every thread that reaches the client while that
  first fetch is in flight blocks on it and then sees the fetched config. One
  fetch, one stream dial, and one telemetry reporter per child, however many
  threads race the first request.
- **`connection_state` never triggers the re-initialization** — a diagnostic
  must not open a socket. A child that has not used the client yet answers
  `:initializing`, which is exactly what it is; it flips to `:connected` on
  first use.
- The child's telemetry aggregators start empty. The parent flushes the data
  it collected before the fork; the child reports only its own.
- **Per-job forking pays per job.** A Resque-style worker that forks a child
  per job (or `Parallel.map` with one row per process) pays, in each child
  that touches the client, one config fetch, one SSE dial, and one telemetry
  POST at exit. That is the price of the child holding its own current config
  and its own telemetry window, and it is deliberate — the delivery service
  counts each of those connections as a real client. A child that never uses
  the client pays none of it.
- In datadir mode a child whose workspace fails to load never dials the
  network: it logs the failure and, if `data_dir_auto_reload` is on, watches
  for a repaired workspace; otherwise the next use retries the load.

### Puma (clustered mode)

With the automatic fork hook, the typical Puma config needs **no Quonfig
lifecycle wiring** — initialize in your Rails initializer and let the hook
handle the rest:

```ruby
# config/initializers/quonfig.rb
Quonfig.init(Quonfig::Options.new(sdk_key: ENV.fetch('QUONFIG_BACKEND_SDK_KEY')))
```

If you use SemanticLogger you still need to reopen it in each worker — but
leave `Quonfig.fork` out of that block on 3.1+. The SDK has already handled
the fork by the time `on_worker_boot` runs, so calling it there is
unnecessary: it discards the client the hook prepared and builds a second one
in its place (and if the worker has already used the client, the first one's
stream and reporter are orphaned):

```ruby
# config/puma.rb (Ruby 3.1+)
on_worker_boot do
  SemanticLogger.reopen
end
```

If you're on Ruby 3.0 (no `Process._fork`), wire the worker boot hook
manually:

```ruby
# config/puma.rb (Ruby 3.0 only)
on_worker_boot do
  Quonfig.fork          # rebuild a fresh client per worker
  SemanticLogger.reopen # if you use SemanticLogger
end
```

Do **not** add a `before_fork { Quonfig.instance.stop }` — the master's
client does not need to be torn down for the workers to be healthy, and
stopping it means the master stops receiving config.

### Sidekiq

Sidekiq OSS does not fork: it runs jobs on threads inside one process, so
`Quonfig.init` in your initializer is all you need on any Ruby version.

Some jobs *do* fork — the `parallel` gem, an explicit `fork { ... }`, or
Sidekiq Enterprise's swarm mode. On Ruby 3.1+ those are covered
automatically, with nothing to call, and (since 1.4.0) the Sidekiq process
itself keeps streaming config the whole time.

Ruby 3.0 is end-of-life and has no `Process._fork` hook. The `parallel` gem
has no per-worker boot hook to wire a rebuild into either — `Parallel.each`
just runs your block in each child, once per row — so calling `Quonfig.fork`
at the top of the block builds a **new client per row**, each with its own
SSE stream and telemetry reporter. Upgrade to 3.1+ if you can. If you must
stay on 3.0, rebuild once per child process by memoizing on the pid:

```ruby
# Ruby 3.0 only — one rebuild per child process, not one per row.
Parallel.each(batch, in_processes: 4) do |row|
  Quonfig.fork if $quonfig_pid != Process.pid
  $quonfig_pid = Process.pid
  # ...
end
```

### Spring / Bootsnap preloaders

Spring forks the preloader for each command. On Ruby 3.1+ the automatic hook
already rebuilds the client in each spawned command, and the preloader itself
keeps streaming. On Ruby 3.0, either:

1. **Recommended:** initialize lazily — wrap `Quonfig.init` so it only runs
   the first time `Quonfig.instance` is called from a non-preloader process.
2. **Or:** call `Quonfig.fork` from a `Spring.after_fork` hook.

```ruby
# config/spring.rb (Ruby 3.0 only)
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

Forking is handled for you on Ruby 3.1+: the child rebuilds automatically and
the parent is left running (see [Rails integration](#rails-integration)). On
Ruby 3.0, `Quonfig.fork` is the way to "carry" a client into a child — do not
reuse the parent's client object in a child process without it.

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
