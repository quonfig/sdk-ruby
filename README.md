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

## Environment variables

| Variable                    | Purpose                                                                                  |
|-----------------------------|------------------------------------------------------------------------------------------|
| `QUONFIG_BACKEND_SDK_KEY`   | SDK key used to authenticate against the Quonfig API. Used when `sdk_key:` is omitted.   |
| `QUONFIG_DIR`               | Path to a workspace directory. When set, the SDK runs in datadir/offline mode.           |
| `QUONFIG_ENVIRONMENT`       | Environment name (`production`, `staging`, `development`) evaluated in datadir mode.     |
| `QUONFIG_TELEMETRY_URL`     | Overrides the telemetry endpoint. Defaults to `https://telemetry.quonfig.com`.           |

## Constructor options

```ruby
Quonfig::Client.new(
  sdk_key:         '...',                          # required unless QUONFIG_BACKEND_SDK_KEY is set
  api_urls:        ['https://primary.quonfig.com'],
  telemetry_url:   'https://telemetry.quonfig.com',
  enable_sse:      true,
  enable_polling:  false,
  poll_interval:   60,
  init_timeout:    10,
  on_no_default:   :error,
  global_context:  {},
  datadir:         '/path/to/workspace',
  environment:     'production'
)
```

| Option            | Type                       | Default                                                             | Description                                                                                       |
|-------------------|----------------------------|---------------------------------------------------------------------|---------------------------------------------------------------------------------------------------|
| `sdk_key`         | `String`                   | `ENV['QUONFIG_BACKEND_SDK_KEY']`                                    | SDK key for API authentication.                                                                   |
| `api_urls`        | `Array<String>`            | `['https://primary.quonfig.com']`                                    | Ordered list of API base URLs to try. SSE stream URLs are derived by prepending `stream.` to each hostname. |
| `telemetry_url`   | `String`                   | `https://telemetry.quonfig.com` (or `ENV['QUONFIG_TELEMETRY_URL']`) | Base URL for the telemetry service.                                                               |
| `enable_sse`      | `Boolean`                  | `true`                                                              | Receive real-time updates over Server-Sent Events.                                                |
| `enable_polling`  | `Boolean`                  | `false`                                                             | Poll the API on an interval as a fallback.                                                        |
| `poll_interval`   | `Integer` (seconds)        | `60`                                                                | Polling interval when `enable_polling` is `true`.                                                 |
| `init_timeout`    | `Integer` (seconds)        | `10`                                                                | Maximum time to wait for the initial config load.                                                 |
| `on_no_default`   | `Symbol`                   | `:error`                                                            | Behavior when a key has no value and no default: `:error`, `:warn`, or `:ignore`.                 |
| `global_context`  | `Hash`                     | `{}`                                                                | Context applied to every evaluation.                                                              |
| `datadir`         | `String`                   | `ENV['QUONFIG_DIR']`                                                | Path to a local workspace. When set, the SDK runs offline from disk.                              |
| `environment`     | `String`                   | `ENV['QUONFIG_ENVIRONMENT']`                                        | Environment to evaluate in datadir mode. Required when `datadir` is set.                          |

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

## Documentation

Full documentation, including SPEC, SDK reference, and operational guides, is
available at [https://quonfig.com/docs](https://quonfig.com/docs).

## License

MIT
