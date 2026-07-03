# frozen_string_literal: true

require 'test_helper'
require 'webrick'
require 'json'

# Verifies Client#initialize (qfg-s7h) wires HTTP fetch + ConfigStore together
# so `Quonfig.get(...)` / `Quonfig.enabled?(...)` return real values — not the
# defaults — when only an `sdk_key:` + `api_urls:` are supplied. This is the
# regression test for the P0 documented in test-ruby/FRICTION.md where
# network-mode was accepted but silently ignored in v0.0.3.
class TestClientNetworkMode < Minitest::Test
  PORT = 18_094

  SAMPLE_CONFIG = {
    'id' => 'c1',
    'key' => 'log-levels.test-ruby',
    'type' => 'log_level',
    'valueType' => 'log_level',
    'sendToClientSdk' => false,
    'default' => {
      'rules' => [
        {
          'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
          'value' => { 'type' => 'log_level', 'value' => 'WARN' }
        }
      ]
    }
  }.freeze

  def setup
    super
    @server = nil
    @fetch_count = 0
  end

  def teardown
    @server&.shutdown
    super
  end

  def start_server
    log = WEBrick::Log.new(StringIO.new)
    @server = WEBrick::HTTPServer.new(
      Port: PORT, Logger: log, AccessLog: []
    )
    @server.mount_proc '/api/v2/configs' do |_req, res|
      @fetch_count += 1
      res.status = 200
      res['Content-Type'] = 'application/json'
      res['ETag'] = "v#{@fetch_count}"
      res.body = JSON.generate(
        'configs' => [SAMPLE_CONFIG],
        'meta' => { 'version' => "v#{@fetch_count}", 'environment' => 'dev' }
      )
    end
    Thread.new { @server.start }
    # Wait for server to be ready.
    50.times do
      break if tcp_open?

      sleep 0.05
    end
  end

  def tcp_open?
    require 'socket'
    TCPSocket.new('127.0.0.1', PORT).tap(&:close)
    true
  rescue StandardError
    false
  end

  def test_initialize_fetches_configs_from_api_urls_and_populates_store
    start_server

    client = Quonfig::Client.new(
      sdk_key: 'test-key',
      api_urls: ["http://127.0.0.1:#{PORT}"],
      enable_sse: false,
      enable_polling: false
    )

    assert_equal 1, @fetch_count, 'expected exactly one HTTP fetch during init'
    assert_includes client.keys, 'log-levels.test-ruby'
    assert_equal 'WARN', client.get('log-levels.test-ruby', 'default')
  ensure
    client&.stop
  end

  def test_initialize_raises_on_fetch_failure_by_default
    # No server started -> connection refused everywhere
    assert_raises(RuntimeError, Quonfig::Errors::InitializationTimeoutError) do
      Quonfig::Client.new(
        sdk_key: 'test-key',
        api_urls: ['http://127.0.0.1:1'], # almost certainly unreachable
        enable_sse: false,
        enable_polling: false,
        initialization_timeout_sec: 2
      )
    end
  end

  def test_initialize_returns_empty_store_when_on_init_failure_is_return
    client = Quonfig::Client.new(
      sdk_key: 'test-key',
      api_urls: ['http://127.0.0.1:1'],
      enable_sse: false,
      enable_polling: false,
      initialization_timeout_sec: 2,
      on_init_failure: Quonfig::Options::ON_INITIALIZATION_FAILURE::RETURN
    )

    assert_empty client.keys
    assert_logged [/Initialization did not complete cleanly/]
  ensure
    client&.stop
  end

  # qfg-xpln.2: In SDK-key delivery mode the server scopes each config to ONE
  # environment using a singular `environment` block plus `meta.environment` =
  # the active env id. The consumer does NOT pin an environment; the SDK must
  # take the active env from `meta.environment` (sdk-go: c.envID =
  # envelope.Meta.Environment). Before the fix, the evaluator's env_id was
  # frozen to @options.environment (nil here), so the env override silently
  # fell through to `default`.
  ENV_SCOPED_CONFIG = {
    'id' => 'c-env',
    'key' => 'flag.env-scoped',
    'type' => 'bool',
    'valueType' => 'bool',
    'sendToClientSdk' => false,
    'default' => {
      'rules' => [
        {
          'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
          'value' => { 'type' => 'bool', 'value' => true }
        }
      ]
    },
    'environment' => {
      'id' => 'development',
      'rules' => [
        {
          'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
          'value' => { 'type' => 'bool', 'value' => false }
        }
      ]
    }
  }.freeze

  def start_env_scoped_server
    log = WEBrick::Log.new(StringIO.new)
    @server = WEBrick::HTTPServer.new(
      Port: PORT, Logger: log, AccessLog: []
    )
    @server.mount_proc '/api/v2/configs' do |_req, res|
      @fetch_count += 1
      res.status = 200
      res['Content-Type'] = 'application/json'
      res['ETag'] = "v#{@fetch_count}"
      res.body = JSON.generate(
        'configs' => [ENV_SCOPED_CONFIG],
        'meta' => { 'version' => "v#{@fetch_count}", 'environment' => 'development' }
      )
    end
    Thread.new { @server.start }
    50.times do
      break if tcp_open?

      sleep 0.05
    end
  end

  def test_env_override_applied_from_meta_environment_when_no_pin
    prev_env = ENV.delete('QUONFIG_ENVIRONMENT')
    start_env_scoped_server

    client = Quonfig::Client.new(
      sdk_key: 'test-key',
      api_urls: ["http://127.0.0.1:#{PORT}"],
      enable_sse: false,
      enable_polling: false,
      # Disable telemetry so the background reporter doesn't POST to a
      # non-existent telemetry endpoint and trip the teardown log check.
      context_upload_mode: :none,
      collect_evaluation_summaries: false
      # NO environment: option, NO QUONFIG_ENVIRONMENT
    )

    # The env block (id 'development', value false) must win over default
    # (value true) because meta.environment == 'development'.
    assert_equal false, client.get('flag.env-scoped', :missing),
                 'expected env override (false) from meta.environment, not default (true)'
  ensure
    client&.stop
    ENV['QUONFIG_ENVIRONMENT'] = prev_env if prev_env
  end

  # qfg-pinh: In DELIVERY (SDK-key) mode the server's meta.environment is
  # AUTHORITATIVE. An explicit environment pin (environment: option or
  # QUONFIG_ENVIRONMENT) is DATADIR-ONLY and must be IGNORED in delivery mode.
  # Canonical reference = sdk-go: the evaluator always evaluates against the
  # installed envelope's meta.environment; the pin never branches eval in
  # delivery mode.
  #
  # Realistic envelope: config environment.id == meta.environment ==
  # 'development' (value false); default true. Pin = 'staging' (mismatch).
  # Expect the env override (false), NOT the pin, NOT the default (true).
  def test_pin_ignored_in_delivery_mode_meta_environment_authoritative
    prev_env = ENV.delete('QUONFIG_ENVIRONMENT')
    start_env_scoped_server

    client = Quonfig::Client.new(
      sdk_key: 'test-key',
      api_urls: ["http://127.0.0.1:#{PORT}"],
      enable_sse: false,
      enable_polling: false,
      context_upload_mode: :none,
      collect_evaluation_summaries: false,
      environment: 'staging' # mismatched pin — must be IGNORED in delivery mode
    )

    assert_equal false, client.get('flag.env-scoped', :missing),
                 'expected env override (false) from meta.environment=development, ' \
                 'NOT the pin (staging) and NOT default (true)'
    assert_logged [/environment 'staging' was set but the client is in delivery/]
  ensure
    client&.stop
    ENV['QUONFIG_ENVIRONMENT'] = prev_env if prev_env
  end

  # qfg-pinh: when a pin is set but the client is in delivery mode, emit a WARN
  # through the SDK logger exactly once at init.
  def test_warn_emitted_when_pin_set_in_delivery_mode
    prev_env = ENV.delete('QUONFIG_ENVIRONMENT')
    start_env_scoped_server

    client = Quonfig::Client.new(
      sdk_key: 'test-key',
      api_urls: ["http://127.0.0.1:#{PORT}"],
      enable_sse: false,
      enable_polling: false,
      context_upload_mode: :none,
      collect_evaluation_summaries: false,
      environment: 'staging'
    )

    assert_logged [
      /environment 'staging' was set but the client is in delivery \(SDK-key\) mode; the active environment is determined by the SDK key, so this setting is ignored \(it applies only when loading from a local data dir\)/
    ]
  ensure
    client&.stop
    ENV['QUONFIG_ENVIRONMENT'] = prev_env if prev_env
  end

  # qfg-41nh.6 (WS2.4, liveness honesty): during a TOTAL outage with
  # on_init_failure: :return, the fallback poll worker must not stamp
  # record_refresh! or fire on_update on failed ticks. Pre-fix the worker
  # stamped + notified on EVERY tick regardless of fetch outcome, so ready?
  # reported true over an EMPTY store and last_successful_refresh advanced
  # while nothing had ever been fetched — a monitoring lie during exactly the
  # incident window where those signals matter.
  def test_failed_poll_ticks_do_not_stamp_refresh_or_fire_on_update
    updates = 0
    client = Quonfig::Client.new(
      sdk_key: 'test-key',
      api_urls: ['http://127.0.0.1:1'], # unreachable — total outage
      enable_sse: false,
      fallback_poll_enabled: true,
      fallback_poll_interval_ms: 100,
      init_timeout_ms: 2000,
      on_init_failure: Quonfig::Options::ON_INITIALIZATION_FAILURE::RETURN,
      context_upload_mode: :none,
      collect_evaluation_summaries: false
    )
    client.on_update { updates += 1 }

    # Let several failed poll ticks elapse (interval 100ms).
    sleep 0.6

    assert_empty client.keys, 'store must stay empty through a total outage'
    refute client.ready?,
           'ready? must NOT report ready with an empty store when every fetch has failed'
    assert_nil client.last_successful_refresh,
               'last_successful_refresh must not advance on failed poll ticks'
    assert_equal 0, updates, 'on_update must not fire on failed poll ticks'

    assert_logged [
      /Initialization did not complete cleanly/,
      /fallback poller engaged/
    ]
  ensure
    client&.stop
  end

  # qfg-41nh.6 (WS2.4, immediate fetch on engage): when the fallback poller
  # engages it must fetch IMMEDIATELY, not sleep a full interval first —
  # matching sdk-go's fallback_poller.go engage() (immediate Fetch, then
  # ticker). Pre-fix the worker slept first, so with the default 60s interval
  # the first post-engage data arrived ~180s after SSE loss vs ~120s in go.
  # The engage must also be logged (it was previously silent).
  def test_fallback_poller_fetches_immediately_on_engage
    start_server

    client = Quonfig::Client.new(
      sdk_key: 'test-key',
      api_urls: ["http://127.0.0.1:#{PORT}"],
      enable_sse: false,
      fallback_poll_enabled: true,
      fallback_poll_interval_ms: 60_000, # a sleep-first worker would wait 60s
      context_upload_mode: :none,
      collect_evaluation_summaries: false
    )

    # Init fetch is 1; the engage fetch must land promptly without waiting
    # for the 60s interval.
    wait_for(-> { @fetch_count >= 2 }, max_wait: 3)

    assert_operator @fetch_count, :>=, 2,
                    'poller must fetch immediately on engage (init fetch + engage fetch)'
    assert client.ready?, 'client must be ready after successful fetches'
    refute_nil client.last_successful_refresh

    assert_logged [/fallback poller engaged/]
  ensure
    client&.stop
  end

  def test_initialize_skips_network_when_store_injected
    # store: passed -> Client should not try any I/O. Unreachable URL must
    # be fine when a store is injected.
    store = Quonfig::ConfigStore.new
    client = Quonfig::Client.new(
      Quonfig::Options.new(
        sdk_key: 'test-key',
        api_urls: ['http://127.0.0.1:1'],
        enable_sse: false,
        enable_polling: false
      ),
      store: store
    )
    assert_same store, client.store
  ensure
    client&.stop
  end
end
