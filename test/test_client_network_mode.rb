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
