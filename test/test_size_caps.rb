# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'socket'
require 'minitest/mock'

# Supervisor contract Test 10 — size caps (qfg-6vno.20.5, rule qfg-6vno.8).
# Contract: integration-test-data chaos/supervisor-test-contract.md at
# v2026.10.22.2, "Rule — size caps" and Test 10 cases 1-5.
#
# - One SSE event (any line, and the sum of a multi-line data:) is capped at
#   4 MiB (4,194,304 bytes). Over the cap is not a frame: the connection is a
#   failed attempt, and later connections never report connected until an
#   envelope gets through.
# - A 200 body from /api/v2/configs is capped at 16 MiB (16,777,216 bytes).
#   Over the cap is a failed leg: nothing installed, no ETag stored.
# - A non-2xx body is read to at most 1 KiB and never logged.
# - One WARN per oversized episode (with the cap in bytes); repeats DEBUG.
class TestSizeCaps < Minitest::Test
  EVENT_CAP = 4 * 1024 * 1024
  BODY_CAP = 16 * 1024 * 1024
  CONFIG_KEY = 'size-caps.value'
  CHUNK = 16 * 1024

  def self.envelope(gen, pad_to: nil)
    env = {
      'configs' => [{
        'id' => 'sc-1', 'key' => CONFIG_KEY, 'type' => 'config', 'valueType' => 'string',
        'sendToClientSdk' => false,
        'default' => { 'rules' => [{ 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
                                     'value' => { 'type' => 'string', 'value' => "v#{gen}" } }] }
      }],
      'meta' => { 'version' => "g#{gen}", 'environment' => 'production', 'generation' => gen }
    }
    json = JSON.generate(env.merge('pad' => ''))
    return json unless pad_to

    JSON.generate(env.merge('pad' => 'x' * (pad_to - json.bytesize)))
  end

  SSE_HEADERS = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" \
                "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"

  # Raw HTTP/1.1 server. +sse_script+ gets (attempt, socket, server);
  # +config_script+ gets (hit, request_headers, socket). Both own the response.
  class Server
    attr_reader :port, :config_hits, :sse_attempts, :config_requests

    def initialize(sse_script: nil, config_script: nil)
      @sse_script = sse_script
      @config_script = config_script
      @tcp = TCPServer.new('127.0.0.1', 0)
      @port = @tcp.addr[1]
      @config_hits = 0
      @config_requests = []
      @sse_attempts = 0
      @mutex = Mutex.new
      @stopped = false
      @threads = []
      @acceptor = Thread.new { accept_loop }
    end

    def url
      "http://127.0.0.1:#{@port}"
    end

    def hold(sock)
      sleep 0.01 until @stopped || sock.closed?
    end

    def stopped?
      @stopped
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
      headers = {}
      while (line = sock.gets)
        break if ["\r\n", "\n"].include?(line)

        name, value = line.split(':', 2)
        headers[name.strip.downcase] = value.to_s.strip
      end
      path = request_line.split[1].to_s
      if path.start_with?('/api/v2/sse/config')
        attempt = @mutex.synchronize { (@sse_attempts += 1) - 1 }
        @sse_script.call(attempt, sock, self)
      else
        hit = @mutex.synchronize do
          @config_requests << headers
          @config_hits += 1
        end
        @config_script.call(hit, headers, sock)
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

  def self.write_json(sock, body, etag:, content_length: true, status: '200 OK')
    head = "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nConnection: close\r\n"
    head << "ETag: #{etag}\r\n" if etag
    head << "Content-Length: #{body.bytesize}\r\n" if content_length
    sock.write "#{head}\r\n"
    pos = 0
    while pos < body.bytesize
      sock.write body.byteslice(pos, 256 * 1024)
      pos += 256 * 1024
    end
  end

  def setup
    super
    @capture = CaptureLogger.new
    Quonfig::InternalLogger.user_logger = @capture
    @waits = []
    @edges = []
    @mutex = Mutex.new
    Quonfig::Waits.hook = lambda do |kind, seconds|
      @mutex.synchronize { @waits << seconds } if kind == :sse
      seconds
    end
  end

  def teardown
    @server&.stop
    @client&.stop
    Quonfig::Waits.hook = nil
    Quonfig::InternalLogger.user_logger = nil
    $logs = nil
    super
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def wait_until(seconds, desc)
    deadline = now + seconds
    until yield
      flunk "timed out after #{seconds}s waiting for #{desc}" if now > deadline
      sleep 0.01
    end
  end

  # ---- unit level: the parser stops reading at the cap -------------------

  # Test 10 case 2 (bounded buffering): "data: " + 8 MiB with no newline. The
  # reader must raise once it holds more than the cap, and never buffer more
  # than about the cap plus one chunk.
  def test_line_reader_stops_at_the_cap_on_a_line_with_no_terminator
    reader = Quonfig::SSEConfigClient::LineReader.new
    fed = 0
    peak = 0
    err = assert_raises(Quonfig::SSEConfigClient::SSEEventTooLargeError) do
      reader.feed('data: ') { |_l| flunk 'no line expected' }
      fed += 6
      ((8 * 1024 * 1024) / CHUNK).times do
        reader.feed('x' * CHUNK) { |_l| flunk 'no line expected' }
        fed += CHUNK
        peak = [peak, reader.instance_variable_get(:@buffer).bytesize].max
      end
    end
    assert_match(/4194304/, err.message)
    assert_operator fed, :<=, EVENT_CAP + CHUNK, "kept reading past the cap (#{fed} bytes)"
    assert_operator peak, :<=, EVENT_CAP + CHUNK, "buffered #{peak} bytes"
  end

  def test_line_reader_rejects_a_terminated_line_over_the_cap
    reader = Quonfig::SSEConfigClient::LineReader.new
    assert_raises(Quonfig::SSEConfigClient::SSEEventTooLargeError) do
      reader.feed("data: #{'x' * EVENT_CAP}\n") { |_l| flunk 'oversized line must not be yielded' }
    end
  end

  # SDKs that join multi-line data: SHOULD cap the sum.
  def test_parser_caps_the_sum_of_a_multi_line_data_event
    parser = Quonfig::SSEConfigClient::EventParser.new
    half = 'x' * ((EVENT_CAP / 2) + 10)
    assert_raises(Quonfig::SSEConfigClient::SSEEventTooLargeError) do
      parser.feed("data: #{half}\ndata: #{half}\n\n") { |_e| flunk 'oversized event must not be yielded' }
    end
  end

  # Test 10 case 5 (SSE half): a 3 MiB envelope installs.
  def test_parser_delivers_a_3_mib_envelope
    parser = Quonfig::SSEConfigClient::EventParser.new
    body = "id: g2\ndata: #{self.class.envelope(2, pad_to: 3 * 1024 * 1024)}\n\n"
    events = []
    frames = 0
    pos = 0
    while pos < body.bytesize
      parser.feed(body.byteslice(pos, CHUNK), on_frame: -> { frames += 1 }) { |e| events << e }
      pos += CHUNK
    end
    assert_equal 1, events.size
    assert_equal 1, frames
    assert_equal 'g2', events.first.envelope.meta['version']
  end

  # ---- client level: Test 10 case 1 --------------------------------------

  def boot_client(fallback_poll_interval_ms:, config_gen: ->(hit) { hit == 1 ? 1 : 2 }, &sse_script)
    @server = Server.new(
      sse_script: sse_script,
      config_script: lambda do |hit, _headers, sock|
        TestSizeCaps.write_json(sock, TestSizeCaps.envelope(config_gen.call(hit)), etag: "e#{hit}")
      end
    )
    spy = @edges
    mutex = @mutex
    Quonfig::Options.stub(:derive_stream_url, ->(u) { u }) do
      @client = Quonfig::Client.new(
        sdk_key: 'test-key',
        api_urls: [@server.url],
        telemetry_url: 'http://127.0.0.1:1',
        fallback_poll_interval_ms: fallback_poll_interval_ms,
        context_upload_mode: :none,
        collect_evaluation_summaries: false
      )
    end
    client = @client
    client.define_singleton_method(:handle_sse_state_change) do |state|
      mutex.synchronize { spy << state.to_sym }
      super(state)
    end
    @client
  end

  def sse_waits
    @mutex.synchronize { @waits.dup }
  end

  def edge_states
    @mutex.synchronize { @edges.dup }
  end

  def test_10_1_oversized_sse_event_backs_off_never_connects_and_the_poller_fetches
    big = self.class.envelope(2, pad_to: EVENT_CAP + 1)
    boot_client(fallback_poll_interval_ms: 50) do |_attempt, sock, srv|
      sock.write SSE_HEADERS
      sock.write "id: g2\ndata: #{big}\n\n"
      sock.flush
      srv.hold(sock)
    end

    wait_until(10, 'two SSE connects and a fallback fetch') do
      @server.sse_attempts >= 2 && @server.config_hits >= 2
    end
    sleep 0.3

    refute_includes edge_states, :connected, "an oversized event must never report connected: #{edge_states}"
    refute_equal :connected, @client.connection_state
    assert_operator @server.config_hits, :>=, 2, 'the fallback poller must fetch /api/v2/configs'
    waits = sse_waits
    refute_empty waits
    waits.each_with_index do |w, i|
      assert_operator w, :>=, 2.0 * (2**i), "requested SSE wait #{i} must grow: #{waits}"
    end
    assert_equal 1, @capture.log_count(:warn, /4194304/),
                 "exactly one WARN with the cap expected: #{@capture.lines(:warn)}"
    assert_operator @capture.log_count(:debug, /4194304/), :>=, 1, 'repeats must log at DEBUG'
    assert_equal 0, @capture.log_count(:error, /4194304/)
  end

  # A keepalive alone does not clear the oversized gate; an envelope does.
  def test_oversized_gate_ignores_keepalives_until_an_envelope_installs
    big = self.class.envelope(2, pad_to: EVENT_CAP + 1)
    small = self.class.envelope(3)
    boot_client(fallback_poll_interval_ms: 60_000) do |attempt, sock, srv|
      sock.write SSE_HEADERS
      case attempt
      when 0 then sock.write "id: g2\ndata: #{big}\n\n"
      when 1 then sock.write ": keepalive\n\n"
      else
        sock.write ": keepalive\n\nid: g3\ndata: #{small}\n\n"
        sock.flush
        srv.hold(sock)
      end
    end

    wait_until(12, 'the envelope after the oversized episode') { @client.get(CONFIG_KEY, 'default') == 'v3' }
    sleep 0.2

    states = edge_states
    first_connected = states.index(:connected)
    refute_nil first_connected, "an installed envelope must report connected: #{states}"
    assert_operator @server.sse_attempts, :>=, 3
    # The keepalive-only connection (attempt 1) must not have counted as a
    # frame: it is a failed attempt, so the wait before attempt 2 doubled.
    waits = sse_waits
    assert_operator waits[1], :>=, 4.0, "keepalive must not reset backoff while gated: #{waits}"
    assert_equal 1, @capture.log_count(:warn, /4194304/)
  end

  # qfg-6vno.20.8: only an INSTALLED envelope ends the oversized episode. An
  # envelope the reject-older guard drops (here, an equal generation to the
  # one the initial fetch installed) is not an install: the gate stays set,
  # the connection does not report connected, the backoff keeps growing and
  # the next oversized event is a DEBUG repeat, not a second WARN.
  def test_oversized_gate_is_not_cleared_by_a_dropped_envelope
    big = self.class.envelope(2, pad_to: EVENT_CAP + 1)
    held = self.class.envelope(1) # equal to every config fetch (gen 1)
    boot_client(fallback_poll_interval_ms: 60_000, config_gen: ->(_hit) { 1 }) do |attempt, sock, srv|
      sock.write SSE_HEADERS
      case attempt
      when 1 then sock.write "id: g1\ndata: #{held}\n\n: keepalive\n\n: keepalive\n\n"
      else
        sock.write "id: g2\ndata: #{big}\n\n"
        sock.flush
        srv.hold(sock) if attempt >= 2
      end
    end

    wait_until(12, 'a second oversized event after the dropped envelope') do
      @capture.log_count(:debug, /4194304/) >= 1 || @capture.log_count(:warn, /4194304/) >= 2
    end
    sleep 0.2

    assert_equal 'v1', @client.get(CONFIG_KEY, 'default')
    refute_includes edge_states, :connected, "a dropped envelope must not report connected: #{edge_states}"
    refute_equal :connected, @client.connection_state
    waits = sse_waits
    assert_operator waits[1], :>=, 4.0, "a dropped envelope must not reset backoff while gated: #{waits}"
    assert_equal 1, @capture.log_count(:warn, /4194304/),
                 "a dropped envelope must not end the WARN episode: #{@capture.lines(:warn)}"
  end

  # ---- client level: Test 10 case 2 --------------------------------------

  def test_10_2_no_newline_event_ends_the_connection_and_retries_with_backoff
    boot_client(fallback_poll_interval_ms: 60_000) do |_attempt, sock, srv|
      sock.write SSE_HEADERS
      sock.write 'data: '
      (8 * 1024 * 1024 / (256 * 1024)).times { sock.write('x' * 256 * 1024) }
      sock.flush
      srv.hold(sock)
    end

    wait_until(8, 'a retried SSE connection') { @server.sse_attempts >= 2 }
    assert_operator sse_waits.first, :>=, 2.0, "an oversized event is a failed attempt: #{sse_waits}"
    refute_includes edge_states, :connected
    assert_equal 1, @capture.log_count(:warn, /4194304/)
  end

  # ---- loader level: Test 10 cases 3 and 5 -------------------------------

  def loader_for(server)
    options = Quonfig::Options.new(
      sdk_key: '1-test-sdk-key',
      api_urls: [server.url],
      config_fetch_timeout_ms: 10_000,
      enable_sse: false,
      fallback_poll_enabled: false
    )
    Quonfig::ConfigLoader.new(Quonfig::ConfigStore.new, options)
  end

  def run_oversized_body_case(content_length:)
    big = self.class.envelope(2, pad_to: BODY_CAP + 1)
    @server = Server.new(
      config_script: lambda do |hit, _headers, sock|
        case hit
        when 1 then TestSizeCaps.write_json(sock, TestSizeCaps.envelope(1), etag: 'e1')
        when 2, 3 then TestSizeCaps.write_json(sock, big, etag: 'big', content_length: content_length)
        else sock.write "HTTP/1.1 304 Not Modified\r\nConnection: close\r\n\r\n"
        end
      end
    )
    loader = loader_for(@server)

    assert_equal :updated, loader.fetch!
    assert_equal 'e1', loader.etag

    assert_equal :failed, loader.fetch!, 'a body over 16 MiB is a failed leg'
    assert_equal 'e1', loader.etag, 'the oversized leg must not store its ETag'
    assert_equal 'g1', loader.version, 'nothing from the oversized body may install'

    assert_equal :failed, loader.fetch!
    loader.fetch!
    assert_equal 'e1', @server.config_requests[3]['if-none-match'],
                 'the next request must not send the oversized response ETag'

    assert_equal 1, @capture.log_count(:warn, /16777216/),
                 "exactly one WARN with the cap expected: #{@capture.lines(:warn)}"
    assert_operator @capture.log_count(:debug, /16777216/), :>=, 1, 'repeats must log at DEBUG'
  end

  # Case 3, bounded reading: the 200 body read stops at the cap. The server
  # sends the cap plus 256 KiB of a larger body and then stalls; a client
  # that reads the whole body and measures it afterwards would hang until its
  # deadline instead of failing at once.
  def test_10_3_body_read_stops_at_the_cap
    @server = Server.new(
      config_script: lambda do |_hit, _headers, sock|
        sock.write "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{BODY_CAP * 2}\r\nConnection: close\r\n\r\n"
        chunk = 'x' * (256 * 1024)
        (((BODY_CAP + chunk.bytesize) / chunk.bytesize) + 1).times { sock.write chunk }
        @server.hold(sock)
      end
    )
    conn = Quonfig::HttpConnection.new(@server.url, 'KEY', timeout_ms: 8_000, max_body_bytes: BODY_CAP)
    started = now
    assert_raises(Quonfig::HttpConnection::BodyTooLargeError) { conn.get('/api/v2/configs') }
    elapsed = now - started
    assert_operator elapsed, :<, 5.0, "the read must stop at the cap, took #{elapsed.round(2)}s"
  end

  def test_10_3_oversized_config_body_with_content_length_is_a_failed_leg
    run_oversized_body_case(content_length: true)
  end

  def test_10_3_oversized_config_body_without_content_length_is_a_failed_leg
    run_oversized_body_case(content_length: false)
  end

  # ---- Test 10 case 4: a non-2xx body is read to at most 1 KiB -----------

  NON_2XX_READ_CAP = 1024
  MARKER = 'SIZE-CAPS-NON-2XX-MARKER'

  # The body must stop being read near 1 KiB, not at the 16 MiB cap. The
  # server sends 64 KiB of a 2 MiB 502 body and then stalls: a client that
  # reads the whole body hangs until its deadline; one that stops at 1 KiB
  # returns at once with the status.
  def test_10_4_non_2xx_body_read_stops_at_1_kib
    @server = Server.new(
      config_script: lambda do |_hit, _headers, sock|
        sock.write "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\n" \
                   "Content-Length: #{2 * 1024 * 1024}\r\nConnection: close\r\n\r\n"
        sock.write MARKER * ((64 * 1024) / MARKER.bytesize)
        @server.hold(sock)
      end
    )
    conn = Quonfig::HttpConnection.new(@server.url, 'KEY', timeout_ms: 4_000,
                                                           max_body_bytes: BODY_CAP)
    started = now
    response = conn.get('/api/v2/configs')
    elapsed = now - started
    assert_equal 502, response.status
    assert_operator response.body.to_s.bytesize, :<=, NON_2XX_READ_CAP
    assert_operator elapsed, :<, 2.0, "the non-2xx body read must stop at 1 KiB, took #{elapsed.round(2)}s"
  end

  # Contract case 4: 502 with a 2 MiB body containing a marker. No log line
  # or error message may contain the marker.
  def test_10_4_non_2xx_body_marker_never_logged_or_in_an_error
    body = (MARKER * ((2 * 1024 * 1024) / MARKER.bytesize))
    @server = Server.new(
      config_script: lambda do |_hit, _headers, sock|
        TestSizeCaps.write_json(sock, body, etag: nil, status: '502 Bad Gateway')
      end
    )
    cycle = loader_for(@server).fetch_cycle!
    assert_equal :failed, cycle.result
    assert_equal 502, cycle.statuses[0]
    refute(@capture.lines.any? { |l| l.include?(MARKER) }, 'no log line may carry the non-2xx body')
    refute(cycle.leg_errors.values.any? { |e| e.to_s.include?(MARKER) }, 'no error may carry the non-2xx body')
  end

  # An auth-class status with a body over 16 MiB is still that status (rule
  # R1 sees it), not an oversized 200.
  def test_10_4_auth_class_status_with_a_huge_body_keeps_its_status
    body = 'x' * (BODY_CAP + (1024 * 1024))
    @server = Server.new(
      config_script: lambda do |_hit, _headers, sock|
        TestSizeCaps.write_json(sock, body, etag: nil, status: '401 Unauthorized')
      end
    )
    cycle = loader_for(@server).fetch_cycle!
    assert_equal :failed, cycle.result
    assert_equal 401, cycle.statuses[0], 'the 401 must be recorded for auth-class detection'
    assert cycle.auth_rejected?
    assert_equal 0, @capture.log_count(:warn, /16777216/), 'a 401 is not an oversized 200'
  end

  # The HTTP episode ends at the next installed envelope from that leg, so a
  # later oversized body starts a new episode with its own WARN.
  def test_http_oversized_episode_ends_at_the_next_install
    big = self.class.envelope(9, pad_to: BODY_CAP + 1)
    @server = Server.new(
      config_script: lambda do |hit, _headers, sock|
        case hit
        when 1, 3 then TestSizeCaps.write_json(sock, big, etag: 'big')
        else TestSizeCaps.write_json(sock, TestSizeCaps.envelope(hit), etag: "e#{hit}")
        end
      end
    )
    loader = loader_for(@server)

    assert_equal :failed, loader.fetch!
    assert_equal :updated, loader.fetch!
    assert_equal :failed, loader.fetch!
    assert_equal 2, @capture.log_count(:warn, /16777216/),
                 "an install must end the episode: #{@capture.lines(:warn)}"
  end

  def test_10_5_a_12_mib_config_body_installs
    body = self.class.envelope(4, pad_to: 12 * 1024 * 1024)
    @server = Server.new(
      config_script: ->(_hit, _headers, sock) { TestSizeCaps.write_json(sock, body, etag: 'e12') }
    )
    loader = loader_for(@server)
    assert_equal :updated, loader.fetch!
    assert_equal 'e12', loader.etag
    assert_equal 'g4', loader.version
  end
end
