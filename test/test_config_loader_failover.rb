# frozen_string_literal: true

require 'test_helper'
require 'webrick'
require 'socket'
require 'json'

# Per-URL config-fetch timeout (qfg-7h5d.1.9) — the unit-level analogue of chaos
# scenario f02-primary-hang. A hung primary (accepts the TCP connection but never
# responds) must NOT starve the secondary: each leg in config_api_urls gets its
# own bounded attempt, so the primary aborts fast (~config_fetch_timeout_ms) and
# the loader resolves off the secondary well inside the overall init budget.
#
# RED until the timeout is wired into HttpConnection: without a per-URL read
# deadline, fetch_from(primary) blocks indefinitely and fetch! never returns —
# this test's own join deadline trips and the assertion fails.
class TestConfigLoaderFailover < Minitest::Test
  SECONDARY_PORT = 18_561

  SAMPLE_CONFIG = {
    'id' => 'c1',
    'key' => 'failover.flag',
    'type' => 'config',
    'valueType' => 'bool',
    'default' => { 'rules' => [] }
  }.freeze

  def setup
    super
    @hung_server = nil
    @hung_threads = []
    @secondary = nil
  end

  def teardown
    @hung_server&.close
    @hung_threads.each { |t| t.kill if t.alive? }
    @secondary&.shutdown
    super
  end

  # A raw TCP listener that accepts connections and never writes a byte —
  # models toxiproxy's "timeout" toxic (the f02 hang).
  def start_hung_primary
    @hung_server = TCPServer.new('127.0.0.1', 0)
    port = @hung_server.addr[1]
    @hung_threads << Thread.new do
      loop do
        sock = @hung_server.accept
        # Hold the socket open; never respond.
        @hung_threads << Thread.new do
          begin
            sleep 60
          rescue StandardError
            nil
          end
          begin
            sock.close
          rescue StandardError
            nil
          end
        end
      rescue StandardError
        break
      end
    end
    "http://127.0.0.1:#{port}"
  end

  def start_secondary
    log = WEBrick::Log.new(StringIO.new)
    @secondary = WEBrick::HTTPServer.new(Port: SECONDARY_PORT, Logger: log, AccessLog: [])
    @secondary.mount_proc '/api/v2/configs' do |_req, res|
      res.status = 200
      res['Content-Type'] = 'application/json'
      res['ETag'] = 'secondary-v1'
      res.body = JSON.generate(
        'configs' => [SAMPLE_CONFIG],
        'meta' => { 'version' => 'secondary-v1', 'environment' => 'production', 'generation' => 0 }
      )
    end
    Thread.new { @secondary.start }
    50.times do
      break if tcp_open?(SECONDARY_PORT)

      sleep 0.05
    end
    "http://127.0.0.1:#{SECONDARY_PORT}"
  end

  def tcp_open?(port)
    TCPSocket.new('127.0.0.1', port).tap(&:close)
    true
  rescue StandardError
    false
  end

  # qfg-7h5d.1.14: under the parallel-failover HEDGE the hung primary no longer
  # has to abort before the secondary is tried. The hedge fires the secondary in
  # PARALLEL once config_fetch_hedge_delay_ms elapses (primary still hung), so the
  # SDK resolves off the secondary FAST — well inside the hedge abort — and the
  # hung primary's timeout warning fires on the detached leg at the hedge abort.
  def test_hung_primary_fails_over_to_secondary_inside_budget
    primary_url = start_hung_primary
    secondary_url = start_secondary

    options = Quonfig::Options.new(
      sdk_key: '1-test-sdk-key',
      api_urls: [primary_url, secondary_url],
      # Hedge after 300ms (the hung primary is still in flight), hard-abort the
      # primary leg at 1200ms so its timeout warning fires deterministically.
      config_fetch_hedge_delay_ms: 300,
      config_fetch_hedge_abort_ms: 1200,
      enable_sse: false,
      fallback_poll_enabled: false
    )
    store = Quonfig::ConfigStore.new
    loader = Quonfig::ConfigLoader.new(store, options)

    result = nil
    worker = Thread.new { result = loader.fetch! }

    # The hedge fires the secondary at ~300ms; fetch! returns on its install well
    # before the primary's 1200ms abort. If the hedge never fired (sequential),
    # the hung primary would block this join until the abort and starve readiness.
    completed = worker.join(4)
    worker.kill unless completed

    assert completed, 'fetch! did not return within 4s — the hung primary starved the secondary (hedge did not fire)'
    assert_equal :updated, result, 'expected the secondary leg to satisfy the fetch'
    assert_includes store.keys, 'failover.flag', 'store should hold the secondary-served config'

    # The detached hung-primary leg aborts at the hedge abort (~1200ms) and logs a
    # timeout warning. Wait for it so the strict teardown log check is satisfied
    # (the warning IS the per-leg hedge-abort mechanism firing).
    wait_for(-> { $logs.string =~ %r{error fetching configs from http://127.0.0.1} }, max_wait: 4)
    assert_logged([%r{error fetching configs from http://127.0.0.1}])
  end
end
