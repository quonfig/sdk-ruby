# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'socket'
require 'minitest/mock'

# Supervisor contract Test 5 — callback-throw isolation (qfg-6vno.6.1).
# Contract: integration-test-data chaos/supervisor-test-contract.md at
# v2026.10.22.2, Test 5 and the callback_errors_total metric row.
#
# Drives the real client and SSE worker against a raw local server: the init
# fetch installs g1, then the stream delivers g2 and g3. The on_config_update
# callback raises on its first call only. The raise is caught, counted in
# callback_errors_total{callback="on_config_update"}, logged at ERROR with its
# stack, and is not a worker restart; g3 still installs and the callback runs
# again.
class TestSupervisorCallbackThrow < Minitest::Test
  CONFIG_KEY = 'callback-throw.value'

  def self.envelope(gen)
    JSON.generate(
      'configs' => [{
        'id' => 'ct-1', 'key' => CONFIG_KEY, 'type' => 'config', 'valueType' => 'string',
        'sendToClientSdk' => false,
        'default' => { 'rules' => [{ 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
                                     'value' => { 'type' => 'string', 'value' => "v#{gen}" } }] }
      }],
      'meta' => { 'version' => "g#{gen}", 'environment' => 'production', 'generation' => gen }
    )
  end

  def setup
    super
    @capture = CaptureLogger.new
    Quonfig::InternalLogger.user_logger = @capture
    @stopped = false
    @tcp = TCPServer.new('127.0.0.1', 0)
    @threads = []
    @acceptor = Thread.new { accept_loop }
  end

  def teardown
    @stopped = true
    begin
      @tcp.close
    rescue StandardError
      nil
    end
    @acceptor.join(1)
    @threads.each { |t| t.join(1) }
    @client&.stop
    Quonfig::InternalLogger.user_logger = nil
    $logs = nil
    super
  end

  def accept_loop
    until @stopped
      sock = begin
        @tcp.accept
      rescue StandardError
        break
      end
      @threads << Thread.new(sock) { |s| handle(s) }
    end
  end

  def handle(sock)
    request_line = sock.gets.to_s
    while (line = sock.gets)
      break if ["\r\n", "\n"].include?(line)
    end
    if request_line.split[1].to_s.start_with?('/api/v2/sse/config')
      sock.write "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
      # Give the test time to register on_update before the first envelope.
      sleep 0.5
      sock.write "id: g2\ndata: #{self.class.envelope(2)}\n\n"
      sock.flush
      sleep 0.3
      sock.write "id: g3\ndata: #{self.class.envelope(3)}\n\n"
      sock.flush
      sleep 0.01 until @stopped || sock.closed?
    else
      body = self.class.envelope(1)
      sock.write "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nETag: g1\r\n" \
                 "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
    end
  rescue StandardError
    nil
  ensure
    begin
      sock.close
    rescue StandardError
      nil
    end
  end

  def test_5_on_config_update_throw_is_counted_logged_and_not_a_restart
    url = "http://127.0.0.1:#{@tcp.addr[1]}"
    Quonfig::Options.stub(:derive_stream_url, ->(u) { u }) do
      @client = Quonfig::Client.new(
        sdk_key: 'test-key',
        api_urls: [url],
        telemetry_url: 'http://127.0.0.1:1',
        context_upload_mode: :none,
        collect_evaluation_summaries: false
      )
    end
    calls = 0
    @client.on_update do
      calls += 1
      raise 'user callback boom' if calls == 1
    end

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until @client.get(CONFIG_KEY, 'default') == 'v3' && calls >= 2
      flunk "g3 never installed (value=#{@client.get(CONFIG_KEY, 'default')}, calls=#{calls})" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end

    assert_equal 2, calls, 'the callback runs again (and succeeds) on the next envelope'
    assert_equal 1, @client.callback_errors_total(callback: 'on_config_update')
    assert_equal 0, @client.callback_errors_total(callback: 'on_connection_state_change')
    assert_equal 0, @client.worker_restart_total(layer: '1'), 'a callback raise is not a worker restart'
    assert_equal 0, @client.worker_restart_total(layer: '2')
    assert_equal :connected, @client.connection_state
    refute_nil @client.last_successful_refresh

    errors = @capture.lines(:error).map(&:last)
    hit = errors.find { |l| l.match?(/callback|onConfigUpdate/i) && l.include?('user callback boom') }
    refute_nil hit, "expected an ERROR naming the callback with the exception message: #{errors}"
    assert_includes hit, File.basename(__FILE__), "the ERROR must carry the stack: #{hit}"
  end
end
