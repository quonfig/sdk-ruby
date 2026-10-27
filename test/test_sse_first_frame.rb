# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'socket'
require 'ostruct'
require 'minitest/mock'

# Supervisor contract Test 9: a stream connection is `connected` at its first
# valid frame (qfg-goi1.10.43, fan-out of qfg-goi1.10.9).
# Contract: integration-test-data chaos/supervisor-test-contract.md at
# v2026.10.16.4, "Rule — a connection is `connected` at its first valid frame"
# (including the bounded transparent reconnect for sdk-ruby) and Test 9
# (a)-(d), plus the Test 2 "Reset" amendment.
#
# Unlike the other supervisor tests this drives the REAL client and SSE worker
# against a raw TCPServer on 127.0.0.1. The config endpoint serves envelope
# gen 1 / "v1" on its first hit (the init fetch) and gen 2 / "v2" on every
# later hit, so a value of "v2" proves the fallback poller delivered.
#
# ruby has no public SSE state callback, so the "connected edge" is the
# client's internal handle_sse_state_change(:connected) transition, recorded
# by a spy. connection_state is sampled every 1ms.
class TestSSEFirstFrame < Minitest::Test
  CONFIG_KEY = 'first-frame.value'

  # Spy on the client's SSE state edges. Prepended once; inert unless a test
  # sets TestSSEFirstFrame.edge_recorder.
  module EdgeSpy
    def handle_sse_state_change(new_state)
      rec = TestSSEFirstFrame.edge_recorder
      rec&.call(self, new_state.to_sym)
      super
    end
  end
  Quonfig::Client.prepend(EdgeSpy)

  class << self
    attr_accessor :edge_recorder
  end

  def self.envelope(gen)
    {
      'configs' => [{
        'id' => 'ff-1', 'key' => CONFIG_KEY, 'type' => 'config', 'valueType' => 'string',
        'sendToClientSdk' => false,
        'default' => { 'rules' => [{ 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
                                     'value' => { 'type' => 'string', 'value' => "v#{gen}" } }] }
      }],
      'meta' => { 'version' => "g#{gen}", 'environment' => 'production', 'generation' => gen }
    }
  end

  SSE_HEADERS = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" \
                "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"

  # Raw HTTP/1.1 server. +sse_script+ is called with (attempt, socket, server)
  # after the request is read; it owns the whole response.
  class Server
    attr_reader :port, :config_hits, :sse_attempts

    def initialize(sse_script)
      @sse_script = sse_script
      @tcp = TCPServer.new('127.0.0.1', 0)
      @port = @tcp.addr[1]
      @config_hits = 0
      @sse_attempts = 0
      @mutex = Mutex.new
      @stopped = false
      @threads = []
      @acceptor = Thread.new { accept_loop }
    end

    def stopped?
      @stopped
    end

    # Block until stop (the "hold the stream open" body).
    def hold(sock)
      sleep 0.01 until @stopped || sock.closed?
    end

    def stop
      @stopped = true
      begin
        @tcp.close
      rescue StandardError
        nil
      end
      @acceptor.join(1)
      @threads.each { |t| t.join(1) }
    end

    private

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
      path = request_line.split[1].to_s
      if path.start_with?('/api/v2/sse/config')
        attempt = @mutex.synchronize { (@sse_attempts += 1) - 1 }
        @sse_script.call(attempt, sock, self)
      else
        hit = @mutex.synchronize { @config_hits += 1 }
        body = JSON.generate(TestSSEFirstFrame.envelope(hit == 1 ? 1 : 2))
        sock.write "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nETag: g#{hit}\r\n" \
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
  end

  def setup
    super
    @edges = []
    @waits = []
    @samples = []
    @sampling = true
    @edge_mutex = Mutex.new
    TestSSEFirstFrame.edge_recorder = lambda do |client, state|
      next unless client.equal?(@client)

      @edge_mutex.synchronize { @edges << [state, now] }
    end
    Quonfig::Waits.hook = lambda do |kind, seconds|
      @edge_mutex.synchronize { @waits << seconds } if kind == :sse
      seconds
    end
  end

  def teardown
    @sampling = false
    @sampler&.join(1)
    # Server first: closing a held stream from the server side is what wakes
    # the client's blocked read (a client-side close does not on macOS).
    @server&.stop
    @client&.stop
    Quonfig::Waits.hook = nil
    TestSSEFirstFrame.edge_recorder = nil
    # The SDK logs the explicit single api_url warning, SSE errors and the
    # poller engage; those are expected here, not what these tests assert.
    $logs = nil
    super
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def boot(fallback_poll_interval_ms:, &sse_script)
    @server = Server.new(sse_script)
    url = "http://127.0.0.1:#{@server.port}"
    Quonfig::Options.stub(:derive_stream_url, ->(u) { u }) do
      @client = Quonfig::Client.new(
        sdk_key: 'test-key',
        api_urls: [url],
        telemetry_url: 'http://127.0.0.1:1',
        fallback_poll_interval_ms: fallback_poll_interval_ms,
        context_upload_mode: :none,
        collect_evaluation_summaries: false
      )
    end
    @sampler = Thread.new do
      last = nil
      while @sampling
        state = @client.connection_state
        @edge_mutex.synchronize { @samples << [state, now] } if state != last
        last = state
        sleep 0.001
      end
    end
    @client
  end

  def connected_transitions
    prev = nil
    @edge_mutex.synchronize { @edges.dup }.count do |state, _|
      hit = state == :connected && prev != :connected
      prev = state
      hit
    end
  end

  def edge_states
    @edge_mutex.synchronize { @edges.map(&:first) }
  end

  def sse_waits
    @edge_mutex.synchronize { @waits.dup }
  end

  def states_seen
    @edge_mutex.synchronize { @samples.map(&:first) }
  end

  def poller_active?
    @client.instance_variable_get(:@poll_supervisor)&.alive? || false
  end

  def value
    @client.get(CONFIG_KEY, 'default')
  end

  def wait_until(seconds, desc)
    deadline = now + seconds
    until yield
      if now > deadline
        flunk "timed out after #{seconds}s waiting for #{desc} " \
              "(connection_state=#{@client.connection_state.inspect}, value=#{value.inspect}, " \
              "sse_attempts=#{@server.sse_attempts}, edges=#{edge_states})"
      end
      sleep 0.005
    end
  end

  # 9a: headers only, every attempt. No SSE `connected` edge fires, the
  # frameless end takes the :error path, and the poller engages and delivers
  # v2. The public getter never reports :connected: the init fetch's install
  # alone does not make an SSE client connected (qfg-fi1s).
  def test_9a_headers_only_is_a_failed_attempt_and_the_poller_delivers
    boot(fallback_poll_interval_ms: 50) { |_attempt, sock, _srv| sock.write SSE_HEADERS }

    wait_until(3, 'the fallback poller to engage and deliver v2') { poller_active? && value == 'v2' }

    assert_equal :falling_back, @client.connection_state
    assert_equal 0, connected_transitions, "no SSE connected edge expected, got #{edge_states}"
    assert_includes edge_states, :error
    refute_includes states_seen, :connected, "connection_state reported :connected with no frame: #{states_seen}"

    sleep 2.5
    waits = sse_waits
    assert_operator @server.sse_attempts, :<=, 4, "connects in ~3s must follow the ladder (#{waits})"
    waits.each_with_index do |w, i|
      assert_operator w, :>=, 2.0 * (2**i), "requested SSE wait #{i} must grow: #{waits}"
    end
  end

  # 9b: headers early, keepalive 1s later, hold. Exactly one connected edge,
  # at the keepalive.
  def test_9b_connected_edge_fires_at_the_late_keepalive_not_at_headers
    send_at = nil
    boot(fallback_poll_interval_ms: 5_000) do |_attempt, sock, srv|
      sock.write SSE_HEADERS
      sock.flush
      sleep 1.0
      send_at = now
      sock.write ": keepalive\n\n"
      sock.flush
      srv.hold(sock)
    end

    wait_until(4, 'a connected edge') { connected_transitions.positive? }
    sleep 0.2

    assert_equal 1, connected_transitions, "edges: #{edge_states}"
    refute_includes edge_states, :error
    edge_time = @edge_mutex.synchronize { @edges.find { |s, _| s == :connected }.last }
    assert_operator edge_time, :>=, send_at - 0.05, 'connected edge reported before the keepalive'
    assert_equal :connected, @client.connection_state
    assert_equal 1, @server.sse_attempts
    refute poller_active?
    # Headers-but-no-frame is :initializing on the public getter (qfg-fi1s).
    connected_at = @edge_mutex.synchronize { @samples.find { |s, _| s == :connected }&.last }
    refute_nil connected_at, "connection_state never reported :connected: #{states_seen}"
    assert_operator connected_at, :>=, send_at - 0.05, 'connection_state reported :connected before the keepalive'
    assert_includes states_seen.take_while { |s| s != :connected }, :initializing
  end

  # 9c: one keepalive then close, every attempt. ruby holds connected across
  # the reconnects (bounded transparent reconnect): no :error edge, backoff
  # stays at the initial 1s, poller never engages.
  def test_9c_keepalive_then_close_resets_backoff_and_holds_connected
    boot(fallback_poll_interval_ms: 600) do |_attempt, sock, _srv|
      sock.write SSE_HEADERS
      sock.write ": keepalive\n\n"
    end

    # Each reconnect is a <= 1s jittered wait plus the watchdog's <= 0.25s
    # stop, so three attempts land within ~2.5s; the doubling ladder (2s,
    # 4s) cannot reach three in 4s.
    sleep 4.0

    waits = sse_waits
    assert_operator @server.sse_attempts, :>=, 3, "attempts in 4s (requested SSE waits #{waits})"
    assert(waits.all? { |w| w <= 1.0 }, "requested SSE waits must stay at the initial 1s: #{waits}")
    assert_equal 1, connected_transitions, "edges: #{edge_states}"
    refute_includes edge_states, :error
    refute poller_active?
    refute_includes states_seen, :falling_back
    refute_includes states_seen, :disconnected
    assert_equal :connected, @client.connection_state
    assert_equal 'v1', value
  end

  # Bounded transparent reconnect: connected is held across ONE clean-EOF
  # reconnect only until that next connection ends frameless; then :error at
  # once, the grace timer arms, and the poller takes over with v2.
  def test_bounded_hold_ends_at_the_first_frameless_connection
    boot(fallback_poll_interval_ms: 100) do |attempt, sock, srv|
      sock.write SSE_HEADERS
      if attempt.zero?
        sock.write ": keepalive\n\n"
      elsif attempt >= 2
        srv.hold(sock)
      end
      # attempt 1: headers only, then close
    end

    wait_until(3, 'the frameless second connection to report :error') { edge_states.include?(:error) }
    assert_equal :disconnected, @client.connection_state
    assert_equal 2, @server.sse_attempts
    assert_equal 1, connected_transitions

    wait_until(3, 'the poller to engage after the grace and deliver v2') { poller_active? && value == 'v2' }
  end

  # 9d control: snapshot envelope then hold.
  def test_9d_envelope_then_hold
    boot(fallback_poll_interval_ms: 5_000) do |_attempt, sock, srv|
      sock.write SSE_HEADERS
      sock.write "data: #{JSON.generate(TestSSEFirstFrame.envelope(2))}\n\n"
      sock.flush
      srv.hold(sock)
    end

    wait_until(3, 'the SSE envelope v2') { value == 'v2' }
    sleep 0.2

    assert_equal 1, connected_transitions, "edges: #{edge_states}"
    assert_equal :connected, @client.connection_state
    refute poller_active?
    assert_equal 1, @server.config_hits
  end

  # Test 2 "Reset" amendment and the frame classification, at the
  # SSEConfigClient level (wait hook compresses time and records requests).
  class Reset < Minitest::Test
    def setup
      super
      @waits = []
      @mutex = Mutex.new
      Quonfig::Waits.hook = lambda do |kind, seconds|
        @mutex.synchronize { @waits << seconds } if kind == :sse
        0.001
      end
    end

    def teardown
      @server&.stop
      @client&.close
      Quonfig::Waits.hook = nil
      $logs = nil
      super
    end

    def run_script(attempts_wanted, on_error: nil, &script)
      @server = TestSSEFirstFrame::Server.new(script)
      opts = OpenStruct.new(sse_api_urls: ["http://127.0.0.1:#{@server.port}"], sdk_key: 'k')
      loader = OpenStruct.new(highwater_mark: 0)
      @client = Quonfig::SSEConfigClient.new(opts, loader, nil, Logger.new(StringIO.new), on_error: on_error)
      @client.start { |*| nil }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      until @server.sse_attempts >= attempts_wanted
        flunk "only #{@server.sse_attempts} attempts" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.005
      end
      sleep 0.05
      @mutex.synchronize { @waits.dup }
    end

    def envelope_frame
      "data: #{JSON.generate(TestSSEFirstFrame.envelope(2))}\n\n"
    end

    # conn1 503, conn2 frame + close, conn3 503, conn4 200 no frame + close,
    # conn5 hold. The frame resets; the frameless 200 does not.
    def run_reset(frame)
      run_script(5) do |attempt, sock, srv|
        case attempt
        when 0, 2 then sock.write "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        when 1 then sock.write(TestSSEFirstFrame::SSE_HEADERS + frame)
        when 3 then sock.write TestSSEFirstFrame::SSE_HEADERS
        else
          sock.write TestSSEFirstFrame::SSE_HEADERS
          srv.hold(sock)
        end
      end
    end

    def test_reset_after_envelope_frame_and_not_after_frameless_200
      waits = run_reset(envelope_frame)
      assert_equal [2.0, 1.0, 2.0, 4.0], waits.first(4)
    end

    def test_reset_after_keepalive_frame_and_not_after_frameless_200
      waits = run_reset(": keepalive\n\n")
      assert_equal [2.0, 1.0, 2.0, 4.0], waits.first(4)
    end

    def test_frameless_clean_eof_invokes_on_error
      errors = Queue.new
      run_script(2, on_error: ->(e) { errors << e }) do |_attempt, sock, _srv|
        sock.write TestSSEFirstFrame::SSE_HEADERS
      end
      refute errors.empty?, 'a frameless session end must call on_error'
    end

    def test_keepalive_frame_then_clean_eof_does_not_invoke_on_error
      errors = Queue.new
      run_script(3, on_error: ->(e) { errors << e }) do |_attempt, sock, _srv|
        sock.write("#{TestSSEFirstFrame::SSE_HEADERS}: keepalive\n\n")
      end
      assert errors.empty?, "unexpected on_error: #{errors.size}"
    end

    # Frame classification (contract rule; canary item 2).
    FRAME_CASES = {
      'keepalive' => [": keepalive\n\n", true],
      'bare comment' => [":\n\n", true],
      'envelope' => [:envelope, true],
      'garbage then keepalive' => ["data: {nope\n\n: keepalive\n\n", true],
      'empty body' => ['', false],
      'keepalive cut off by EOF' => [": keepalive\n", false],
      'malformed data' => ["data: {nope\n\n", false],
      'json, not an envelope' => ["data: {\"a\":1}\n\n", false],
      'envelope with no blank line' => [:envelope_unterminated, false],
      'id-only block' => ["id: 7\n\n", false],
      'bare blank line' => ["\n", false],
      'comment plus id field' => [": hi\nid: 3\n\n", false]
    }.freeze

    def test_parser_frame_classification
      env = JSON.generate(TestSSEFirstFrame.envelope(2))
      FRAME_CASES.each do |name, (body, want)|
        body = "data: #{env}\n\n" if body == :envelope
        body = "data: #{env}\n" if body == :envelope_unterminated
        parser = Quonfig::SSEConfigClient::EventParser.new(logger: Logger.new(StringIO.new))
        frames = 0
        parser.feed(body, on_frame: -> { frames += 1 }) { |_e| nil }
        assert_equal want, frames.positive?, "case #{name.inspect}: frame seen"
      end
    end
  end
end
