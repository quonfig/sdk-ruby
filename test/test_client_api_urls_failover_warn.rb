# frozen_string_literal: true

require 'test_helper'
require 'webrick'
require 'json'

# qfg-41nh.26 (WS5.3): the SDK's default (and every QUONFIG_DOMAIN-derived)
# api_urls list carries a primary AND a secondary leg, and the HTTP
# config-fetch hedges/fails over between them. An explicit `api_urls:` replaces
# that list wholesale, so a single-entry override silently drops the secondary
# and disables automatic failover. The client emits ONE WARN at init when the
# caller explicitly set api_urls AND the resolved list has fewer than two legs.
# It must NOT warn on a two-URL explicit list, nor on the default/derived list.
class TestClientApiUrlsFailoverWarn < Minitest::Test
  PORT = 18_097

  FAILOVER_WARN = /explicit api_urls disables automatic failover to the secondary/

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
    @server = WEBrick::HTTPServer.new(Port: PORT, Logger: log, AccessLog: [])
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

  def build_client(api_urls)
    Quonfig::Client.new(
      sdk_key: 'test-key',
      api_urls: api_urls,
      enable_sse: false,
      enable_polling: false,
      # Keep telemetry quiet so the only log we ever see is the failover warn.
      context_upload_mode: :none,
      collect_evaluation_summaries: false
    )
  end

  # (a) A single explicit api_url drops the secondary -> the SDK must warn once.
  def test_single_explicit_api_url_warns_failover_disabled
    start_server
    client = build_client(["http://127.0.0.1:#{PORT}"])

    assert_logged [FAILOVER_WARN]
  ensure
    client&.stop
  end

  # (b) Two explicit api_urls keep the secondary leg -> failover stays on, no warn.
  def test_two_explicit_api_urls_do_not_warn
    start_server
    # Primary answers fast (local), so the hedge never contacts the secondary;
    # both point at the same server purely so init succeeds cleanly.
    client = build_client(["http://127.0.0.1:#{PORT}", "http://127.0.0.1:#{PORT}"])

    refute_match FAILOVER_WARN, $logs.string,
                 'two explicit URLs keep failover and must not warn'
    # No warning expected; mark the (empty) log buffer handled for teardown.
    $logs = nil
  ensure
    client&.stop
  end

  # (c) The default (non-explicit) list always derives BOTH legs, so the gate is
  # false and no warn fires. Verified at the Options layer so it stays
  # deterministic and offline (the default derives real quonfig.com URLs).
  def test_default_api_urls_are_not_explicit_and_carry_both_legs
    options = Quonfig::Options.new(sdk_key: 'test-key')

    refute options.api_urls_explicit,
           'not passing api_urls must not be treated as an explicit override'
    assert_equal 2, options.config_api_urls.length,
                 'the default/derived list must carry both a primary and a secondary leg'
  end
end
