# frozen_string_literal: true

require 'test_helper'
require 'webrick'
require 'ostruct'
require 'json'

class TestSSEConfigClient < Minitest::Test
  SAMPLE_JSON_PAYLOAD = '{"configs":[],"meta":{"version":"1","environment":"test"}}'

  # qfg-47c2.9: read deadline 300s -> 90s so a silent SSE stall trips within
  # 3x the 30s server heartbeat instead of after 5 minutes.
  def test_default_sse_read_timeout_is_90_seconds
    opts = Quonfig::SSEConfigClient::Options.new
    assert_equal 90, opts.sse_read_timeout
  end

  def test_default_reconnect_delays
    opts = Quonfig::SSEConfigClient::Options.new
    assert_equal 1.0, opts.sse_initial_reconnect_delay
    assert_equal 30.0, opts.sse_max_reconnect_delay
  end

  def test_headers_basic_auth_uses_1_prefix
    prefab_options = OpenStruct.new(sse_api_urls: ['https://stream.example.com'], sdk_key: 'mykey')
    config_loader = OpenStruct.new(highwater_mark: 0)
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader)

    h = client.headers

    assert_equal "Basic #{Base64.strict_encode64('1:mykey')}", h['Authorization']
    assert_equal 'text/event-stream', h['Accept']
    assert_match(/\Aruby-\d+\.\d+\.\d+/, h['X-Quonfig-SDK-Version'])
    refute h.key?('X-Reforge-SDK-Version')
  end

  def test_headers_includes_last_event_id_when_cursor_present
    prefab_options = OpenStruct.new(sse_api_urls: ['https://stream.example.com'], sdk_key: 'k')
    config_loader = OpenStruct.new(highwater_mark: 42)
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader)

    assert_equal '42', client.headers['Last-Event-Id']
  end

  def test_headers_omits_last_event_id_when_cursor_absent
    prefab_options = OpenStruct.new(sse_api_urls: ['https://stream.example.com'], sdk_key: 'k')
    config_loader = OpenStruct.new(highwater_mark: 0)
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader)

    refute client.headers.key?('Last-Event-Id')
  end

  def test_current_cursor_prefers_string_version_over_highwater
    prefab_options = OpenStruct.new(sse_api_urls: ['https://stream.example.com'], sdk_key: 'k')
    config_loader = OpenStruct.new(version: 'v-abc', highwater_mark: 99)
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader)

    assert_equal 'v-abc', client.current_cursor
  end

  def test_current_cursor_falls_back_to_highwater_when_version_blank
    prefab_options = OpenStruct.new(sse_api_urls: ['https://stream.example.com'], sdk_key: 'k')
    config_loader = OpenStruct.new(version: '', highwater_mark: 7)
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader)

    assert_equal '7', client.current_cursor
  end

  # qfg-ll6r / qfg-35sm: Layer 1 (SSE) restart_total counter. Surfaced via
  # Client#worker_restart_total(layer: '1'); chaos scenario 09 asserts >= 5
  # after 5 proxy flaps in 30s. Counted in exactly one place — the reconnect
  # site in run_loop — so there is no double-count and no log-line scraping.
  def test_restart_total_starts_at_zero
    prefab_options = OpenStruct.new(sse_api_urls: ['https://stream.example.com'], sdk_key: 'test')
    config_loader = OpenStruct.new(highwater_mark: 0)
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader)
    assert_equal 0, client.restart_total
  end

  # qfg-35sm regression of qfg-ie49: a clean server-side FIN must still bump
  # restart_total. The previous ld-eventsource adapter missed this because
  # ld-eventsource reconnected internally without firing on_error. With an
  # SDK-owned loop the clean-FIN path falls straight back into the loop,
  # which increments the counter before reconnecting.
  class CleanFinEndpoint < WEBrick::HTTPServlet::AbstractServlet
    @counter = 0
    class << self
      attr_accessor :counter
    end

    def do_GET(_request, response)
      response.status = 200
      response['Content-Type'] = 'text/event-stream'
      response['Cache-Control'] = 'no-cache'
      response.chunked = false
      self.class.counter += 1
      response.body = "id: #{self.class.counter}\n" \
                      "event: message\n" \
                      "data: #{TestSSEConfigClient::SAMPLE_JSON_PAYLOAD}\n\n"
    end
  end

  def test_restart_total_increments_on_clean_fin_reconnect
    CleanFinEndpoint.counter = 0
    server, = start_webrick_server(4569, CleanFinEndpoint)

    config_loader = OpenStruct.new(highwater_mark: 0)
    prefab_options = OpenStruct.new(sse_api_urls: ['http://localhost:4569'], sdk_key: 'test')
    last_event_id = nil
    client = nil

    begin
      Thread.new { server.start }

      sse_options = Quonfig::SSEConfigClient::Options.new(sse_initial_reconnect_delay: 0.05)
      client = Quonfig::SSEConfigClient.new(prefab_options, config_loader, sse_options)

      client.start do |_envelope, event, _source|
        last_event_id = event.id.to_i
      end

      wait_for -> { last_event_id && last_event_id > 3 }
    ensure
      client&.close
      server.stop
    end

    assert client.restart_total >= 3,
           "restart_total must count clean-FIN reconnects (got #{client.restart_total})"
  end

  def test_recovering_from_disconnection
    server, = start_webrick_server(4567, DisconnectingEndpoint)

    config_loader = OpenStruct.new(highwater_mark: 4)
    prefab_options = OpenStruct.new(sse_api_urls: ['http://localhost:4567'], sdk_key: 'test')
    last_event_id = nil
    client = nil

    begin
      Thread.new { server.start }

      sse_options = Quonfig::SSEConfigClient::Options.new(sse_initial_reconnect_delay: 0.05)
      client = Quonfig::SSEConfigClient.new(prefab_options, config_loader, sse_options)

      client.start { |_configs, event, _source| last_event_id = event.id.to_i }

      wait_for -> { last_event_id && last_event_id > 1 }
    ensure
      client&.close
      server.stop

      refute_nil last_event_id, 'Expected to have received an event'
      assert last_event_id > 1, 'Expected to have received multiple events (indicating a retry)'
    end
  end

  def test_recovering_from_an_error
    log_output = StringIO.new
    logger = Logger.new(log_output)

    server, = start_webrick_server(4568, ErroringEndpoint)

    config_loader = OpenStruct.new(highwater_mark: 4)
    prefab_options = OpenStruct.new(sse_api_urls: ['http://localhost:4568'], sdk_key: 'test')
    last_event_id = nil
    client = nil

    begin
      Thread.new { server.start }

      sse_options = Quonfig::SSEConfigClient::Options.new(sse_initial_reconnect_delay: 0.05)
      client = Quonfig::SSEConfigClient.new(prefab_options, config_loader, sse_options, logger)

      client.start { |_configs, event, _source| last_event_id = event.id.to_i }

      wait_for -> { last_event_id && last_event_id > 2 }
    ensure
      server.stop
      client&.close

      refute_nil last_event_id, 'Expected to have received an event'
      assert last_event_id > 2, 'Expected to have received multiple events (indicating a reconnect)'
    end

    # Functional assertion above is what matters; the error log is a
    # secondary check that we surface non-200s to the operator.
    log_lines = log_output.string.split("\n")
    assert log_lines.any? { |l| l.match?(/SSE Streaming Error.*HTTP 500/) },
           "Expected an HTTP 500 error log, got:\n#{log_lines.join("\n")}"
  end

  def test_on_error_invokes_error_callback_for_http_status
    server, = start_webrick_server(4570, AlwaysErroringEndpoint)
    errors = []
    client = nil

    begin
      Thread.new { server.start }

      prefab_options = OpenStruct.new(sse_api_urls: ['http://localhost:4570'], sdk_key: 'k')
      config_loader = OpenStruct.new(highwater_mark: 0)
      sse_options = Quonfig::SSEConfigClient::Options.new(sse_initial_reconnect_delay: 0.05)
      client = Quonfig::SSEConfigClient.new(
        prefab_options, config_loader, sse_options, nil,
        on_error: ->(e) { errors << e }
      )

      client.start { |_e, _ev, _s| }
      wait_for -> { errors.size >= 2 }
    ensure
      client&.close
      server.stop
    end

    refute_empty errors
    assert errors.first.is_a?(Quonfig::SSEConfigClient::SSEHTTPStatusError),
           "Expected SSEHTTPStatusError, got #{errors.first.class}"
    assert_equal 500, errors.first.status_code

    # Surface the error log so the teardown stderr check doesn't trip.
    assert_logged([/SSE Streaming Error.*HTTP 500/])
  end

  # qfg-i5xv: 401/403/404 are not recoverable by retrying — bad keys,
  # revoked permissions, and missing workspaces will not heal on a reconnect.
  # The SDK must classify these as terminal: invoke on_error with a
  # SSEHTTPTerminalError sentinel, mark the client stopped, exit the loop,
  # and DO NOT bump restart_total. At launch scale a single misconfigured
  # customer key could otherwise hold an indefinite ~2 rpm reconnect attempt
  # against api-delivery-sse — see bead description.
  def assert_terminal_status_behavior(status_code, port)
    TerminalStatusEndpoint.status_code = status_code
    TerminalStatusEndpoint.hits = 0

    server, = start_webrick_server(port, TerminalStatusEndpoint)
    errors = []
    client = nil

    begin
      Thread.new { server.start }

      prefab_options = OpenStruct.new(sse_api_urls: ["http://localhost:#{port}"], sdk_key: 'k')
      config_loader = OpenStruct.new(highwater_mark: 0)
      sse_options = Quonfig::SSEConfigClient::Options.new(sse_initial_reconnect_delay: 0.05)
      client = Quonfig::SSEConfigClient.new(
        prefab_options, config_loader, sse_options, nil,
        on_error: ->(e) { errors << e }
      )

      client.start { |_e, _ev, _s| }

      # Give the loop more than enough time to retry many times if it
      # was going to. With 0.05s initial reconnect delay and ~5s wall
      # clock, a non-terminal classification would produce dozens of hits.
      sleep 1.0
      wait_for(-> { !client.instance_variable_get(:@worker).alive? }, max_wait: 3)
    ensure
      client&.close
      server.stop
    end

    worker = client.instance_variable_get(:@worker)
    refute worker&.alive?, "worker thread must exit cleanly on terminal HTTP #{status_code}"
    assert_equal 1, TerminalStatusEndpoint.hits,
                 "terminal HTTP #{status_code} must produce exactly one connect attempt (got #{TerminalStatusEndpoint.hits})"
    assert_equal 0, client.restart_total,
                 "terminal HTTP #{status_code} must NOT bump restart_total (got #{client.restart_total})"
    assert_equal 1, errors.size,
                 "on_error must fire exactly once for terminal HTTP #{status_code} (got #{errors.size})"
    assert errors.first.is_a?(Quonfig::SSEConfigClient::SSEHTTPTerminalError),
           "expected SSEHTTPTerminalError, got #{errors.first.class}"
    assert_equal status_code, errors.first.status_code

    assert_logged([/SSE.*Terminal.*HTTP #{status_code}/])
  end

  def test_terminal_classification_401_unauthorized
    assert_terminal_status_behavior(401, 4574)
  end

  def test_terminal_classification_403_forbidden
    assert_terminal_status_behavior(403, 4575)
  end

  def test_terminal_classification_404_not_found
    assert_terminal_status_behavior(404, 4576)
  end

  # qfg-i5xv: a 503 (or any 5xx) is transient — the SDK must keep retrying,
  # bump restart_total per reconnect, and NOT invoke a terminal-error
  # callback. This guards against an over-broad fix that classifies every
  # non-200 as terminal.
  def test_500_is_not_terminal
    server, = start_webrick_server(4577, AlwaysErroringEndpoint)
    errors = []
    client = nil

    begin
      Thread.new { server.start }

      prefab_options = OpenStruct.new(sse_api_urls: ['http://localhost:4577'], sdk_key: 'k')
      config_loader = OpenStruct.new(highwater_mark: 0)
      sse_options = Quonfig::SSEConfigClient::Options.new(sse_initial_reconnect_delay: 0.05)
      client = Quonfig::SSEConfigClient.new(
        prefab_options, config_loader, sse_options, nil,
        on_error: ->(e) { errors << e }
      )

      client.start { |_e, _ev, _s| }
      wait_for -> { client.restart_total >= 2 }
    ensure
      client&.close
      server.stop
    end

    worker = client.instance_variable_get(:@worker)
    refute worker&.alive?, 'worker should be stopped after client.close'
    assert client.restart_total >= 2,
           "transient 500 must keep retrying (restart_total=#{client.restart_total})"
    refute errors.any?(Quonfig::SSEConfigClient::SSEHTTPTerminalError),
           "transient 500 must NOT produce SSEHTTPTerminalError, got #{errors.map(&:class).uniq.inspect}"

    assert_logged([/SSE Streaming Error.*HTTP 500/])
  end

  # qfg-i5xv: a healthy session followed by a 401 on reconnect must still
  # deliver the healthy events normally, then stop cleanly when the terminal
  # classification fires. Regression guard against a fix that short-circuits
  # too early (e.g. checking the code before the read_body loop runs).
  def test_terminal_classification_after_healthy_session
    HealthyThenTerminalEndpoint.counter = 0
    HealthyThenTerminalEndpoint.healthy_hits = 0
    HealthyThenTerminalEndpoint.terminal_hits = 0
    HealthyThenTerminalEndpoint.healthy_count = 1
    HealthyThenTerminalEndpoint.terminal_status = 401

    server, = start_webrick_server(4578, HealthyThenTerminalEndpoint)
    errors = []
    seen = []
    client = nil

    begin
      Thread.new { server.start }

      prefab_options = OpenStruct.new(sse_api_urls: ['http://localhost:4578'], sdk_key: 'k')
      config_loader = OpenStruct.new(highwater_mark: 0)
      sse_options = Quonfig::SSEConfigClient::Options.new(sse_initial_reconnect_delay: 0.05)
      client = Quonfig::SSEConfigClient.new(
        prefab_options, config_loader, sse_options, nil,
        on_error: ->(e) { errors << e }
      )

      client.start { |_envelope, event, _source| seen << event.id }
      wait_for(-> { !client.instance_variable_get(:@worker).alive? }, max_wait: 5)
    ensure
      client&.close
      server.stop
    end

    assert_equal 5, seen.size,
                 "5 healthy events must be delivered before terminal classification fires (got #{seen.size})"
    assert_equal 1, HealthyThenTerminalEndpoint.terminal_hits,
                 "exactly one terminal hit (got #{HealthyThenTerminalEndpoint.terminal_hits})"
    terminal_err = errors.find { |e| e.is_a?(Quonfig::SSEConfigClient::SSEHTTPTerminalError) }
    refute_nil terminal_err, "expected terminal error, got #{errors.map(&:class).inspect}"
    assert_equal 401, terminal_err.status_code

    assert_logged([/SSE.*Terminal.*HTTP 401/])
  end

  def test_last_event_id_sent_on_reconnect
    LastEventIdEndpoint.received_ids.clear
    server, = start_webrick_server(4571, LastEventIdEndpoint)
    client = nil

    begin
      Thread.new { server.start }

      prefab_options = OpenStruct.new(sse_api_urls: ['http://localhost:4571'], sdk_key: 'k')
      config_loader = OpenStruct.new(highwater_mark: 0)
      sse_options = Quonfig::SSEConfigClient::Options.new(sse_initial_reconnect_delay: 0.05)
      client = Quonfig::SSEConfigClient.new(prefab_options, config_loader, sse_options)

      seen = []
      client.start { |_e, event, _s| seen << event.id }
      wait_for -> { seen.size >= 3 }
    ensure
      client&.close
      server.stop
    end

    # First request has no Last-Event-Id, subsequent reconnects send the
    # most recently observed id back to the server.
    assert_nil LastEventIdEndpoint.received_ids.first
    assert_equal '1', LastEventIdEndpoint.received_ids[1]
    assert_equal '2', LastEventIdEndpoint.received_ids[2]
  end

  # qfg-35sm regression: chaos scenario 02 — server stops sending bytes but
  # keeps the socket open. Net::HTTP#read_timeout does not reliably fire for
  # the streaming +read_body do |chunk|+ form, so we need the watchdog to
  # interrupt the worker thread once +sse_read_timeout+ elapses without a
  # chunk. Without the watchdog, restart_total stayed 0 forever while the
  # SSE socket was logically dead.
  class SilentStallServer
    def initialize(port)
      @server = TCPServer.new(port)
      @thread = Thread.new do
        loop do
          sock = @server.accept
          until sock.gets == "\r\n"; end
          sock.write "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nTransfer-Encoding: chunked\r\n\r\n"
          frame = "id: 1\nevent: message\ndata: #{TestSSEConfigClient::SAMPLE_JSON_PAYLOAD}\n\n"
          sock.write "#{frame.bytesize.to_s(16)}\r\n#{frame}\r\n"
          # Hang forever — no more bytes, no FIN.
          sleep 30
        rescue StandardError
          # Client closed; loop and accept the next.
        end
      end
    end

    def close
      @server.close
      @thread.kill
    end
  end

  def test_watchdog_interrupts_silent_stall
    server = SilentStallServer.new(4573)

    prefab_options = OpenStruct.new(sse_api_urls: ['http://localhost:4573'], sdk_key: 'k')
    config_loader = OpenStruct.new(highwater_mark: 0)
    sse_options = Quonfig::SSEConfigClient::Options.new(
      sse_read_timeout: 1,
      sse_initial_reconnect_delay: 0.05
    )
    errors = []
    client = Quonfig::SSEConfigClient.new(
      prefab_options, config_loader, sse_options, nil,
      on_error: ->(e) { errors << e }
    )

    events = []
    client.start { |_envelope, event, _s| events << event.id }

    # 1s deadline + 0.05s reconnect — after 3s we should see at least one
    # interruption + reconnect cycle.
    wait_for -> { client.restart_total >= 1 }
    client.close
    server.close

    assert client.restart_total >= 1,
           "restart_total must reflect watchdog-driven interruption (got #{client.restart_total})"
    assert errors.any?(Quonfig::SSEConfigClient::SSEReadDeadlineExceeded),
           "expected SSEReadDeadlineExceeded in #{errors.inspect}"
    assert_logged([/SSE Streaming Error.*SSEReadDeadlineExceeded/])
  end

  # qfg-tj18: ReadDeadlineWatchdog uses Thread#raise to interrupt the worker.
  # The watchdog mutex covers the *decision* to fire, but once raise returns,
  # the exception is queued and Ruby delivers it at the worker's next
  # interrupt checkpoint. Under a race, that checkpoint can be in the
  # post-rescue stretch of run_loop (the `delay = …` line, the `until`
  # check) or inside interruptible_sleep — neither of which is wrapped by
  # the inner `rescue StandardError` around stream_once. A single late raise
  # there kills the worker Thread.new block and SSE silently stops
  # reconnecting for the lifetime of this client.
  #
  # The fix is Thread.handle_interrupt(SSEReadDeadlineExceeded => :on_blocking)
  # around the run_loop body, plus a paranoid outer rescue. This test stubs
  # stream_once so the worker spends almost all its time in
  # interruptible_sleep, then hammers it with raises — every one of them
  # would escape the Thread block under the old code.
  def test_worker_survives_late_landing_read_deadline_raise
    fake_client_class = Class.new(Quonfig::SSEConfigClient) do
      attr_reader :stream_calls

      def initialize(*args, **kwargs)
        super
        @stream_calls = 0
      end

      private

      def stream_once
        @stream_calls += 1
        envelope = Quonfig::ConfigEnvelope.new(configs: [], meta: {})
        yield Quonfig::StreamEvent.new(envelope, @stream_calls.to_s, '{}')
        # Simulate clean FIN — return immediately, no blocking IO so the
        # only blocking call in run_loop is the inter-iteration sleep.
      end
    end

    prefab_options = OpenStruct.new(sse_api_urls: ['http://localhost:0'], sdk_key: 'k')
    config_loader = OpenStruct.new(highwater_mark: 0)
    sse_options = Quonfig::SSEConfigClient::Options.new(sse_initial_reconnect_delay: 0.05)
    client = fake_client_class.new(prefab_options, config_loader, sse_options)

    client.start { |_e, _ev, _s| nil }

    begin
      wait_for -> { client.stream_calls >= 1 }
      worker = client.instance_variable_get(:@worker)

      50.times do
        break unless worker.alive?

        worker.raise(Quonfig::SSEConfigClient::SSEReadDeadlineExceeded.new('late raise'))
        sleep 0.005
      end

      sleep 0.2

      assert worker.alive?,
             "worker must survive late-landing SSEReadDeadlineExceeded (alive=#{worker.alive?}, stream_calls=#{client.stream_calls})"

      before = client.stream_calls
      wait_for -> { client.stream_calls > before }
      assert client.stream_calls > before,
             "worker must keep reconnecting after contained late raise (#{before} -> #{client.stream_calls})"
    ensure
      client&.close
    end

    # Late-landing raises are expected to be logged as SSE Streaming Error
    # (when caught by the inner rescue) or as the paranoid-rescue line.
    assert_logged([/SSE.*(Streaming Error|late-raise contained|read deadline)/])
  end

  # qfg-m3lk: a buggy on_envelope listener must not look like a transport
  # error. If the user-supplied callback raises, it must be isolated inside
  # stream_once's block so the exception never reaches run_loop's rescue and
  # therefore never bumps restart_total. The connection keeps consuming the
  # stream — one bad callback does not cost a reconnect.
  class FakeStreamingClient < Quonfig::SSEConfigClient
    attr_reader :stream_calls

    def initialize(*args, event_count: 100, **kwargs)
      super(*args, **kwargs)
      @stream_calls = 0
      @event_count = event_count
    end

    private

    def stream_once
      @stream_calls += 1
      @event_count.times do |i|
        envelope = Quonfig::ConfigEnvelope.new(configs: [], meta: {})
        yield Quonfig::StreamEvent.new(envelope, (i + 1).to_s, '{}')
      end
      # Long sleep so the test can assert without racing the reconnect loop.
      # interruptible_sleep on close() will wake us.
      sleep 5
    end
  end

  def test_on_envelope_exception_does_not_trigger_reconnect
    prefab_options = OpenStruct.new(sse_api_urls: ['http://localhost:0'], sdk_key: 'k')
    config_loader = OpenStruct.new(highwater_mark: 0)
    sse_options = Quonfig::SSEConfigClient::Options.new(sse_initial_reconnect_delay: 0.05)
    client = FakeStreamingClient.new(prefab_options, config_loader, sse_options)

    attempts = 0
    client.start do |_envelope, _event, _source|
      attempts += 1
      raise StandardError, 'boom'
    end

    begin
      wait_for -> { attempts >= 100 }
      sleep 0.05

      assert_equal 0, client.restart_total,
                   'callback exceptions must not look like transport errors'
      assert_equal 100, attempts,
                   'all 100 callbacks must be attempted even though each raises'

      worker = client.instance_variable_get(:@worker)
      assert worker.alive?, 'worker thread must survive a raising callback'

      assert_equal 100, client.on_envelope_error_total,
                   'every raise must be counted in on_envelope_error_total'
    ensure
      client&.close
    end

    assert_logged([/SSE on_envelope callback raised.*StandardError.*boom/])
  end

  def test_on_envelope_intermittent_raises_still_process_other_events
    prefab_options = OpenStruct.new(sse_api_urls: ['http://localhost:0'], sdk_key: 'k')
    config_loader = OpenStruct.new(highwater_mark: 0)
    sse_options = Quonfig::SSEConfigClient::Options.new(sse_initial_reconnect_delay: 0.05)
    client = FakeStreamingClient.new(prefab_options, config_loader, sse_options,
                                     event_count: 30)

    delivered = []
    client.start do |_envelope, event, _source|
      id = event.id.to_i
      raise ArgumentError, 'bad event' if (id % 3).zero?

      delivered << id
    end

    begin
      wait_for -> { delivered.size >= 20 }
      sleep 0.05

      assert_equal 0, client.restart_total
      assert_equal 20, delivered.size,
                   "two-thirds of events should be delivered without raising (got #{delivered.size})"
      delivered.each { |id| refute_equal 0, id % 3, "id #{id} should not be a multiple of 3" }
      assert_equal '30', client.instance_variable_get(:@last_event_id),
                   'last_event_id must advance even across raising callbacks'
    ensure
      client&.close
    end

    assert_logged([/SSE on_envelope callback raised.*ArgumentError.*bad event/])
  end

  def test_on_envelope_does_not_swallow_non_standard_error
    # Exception / SystemExit / Interrupt must propagate — otherwise Ctrl-C
    # mid-callback is unkillable. We test this at the unit level (no worker
    # thread) by calling the safe helper directly.
    prefab_options = OpenStruct.new(sse_api_urls: ['http://localhost:0'], sdk_key: 'k')
    config_loader = OpenStruct.new(highwater_mark: 0)
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader)

    envelope = Quonfig::ConfigEnvelope.new(configs: [], meta: {})
    event = Quonfig::StreamEvent.new(envelope, '1', '{}')

    raising = ->(_e, _ev, _s) { raise Interrupt }

    assert_raises(Interrupt) do
      client.send(:invoke_on_envelope_safely, raising, event)
    end
    assert_equal 0, client.on_envelope_error_total,
                 'non-StandardError must NOT be counted as a callback error'
  end

  def test_close_interrupts_in_flight_stream
    server, = start_webrick_server(4572, SlowEndpoint)
    nil

    Thread.new { server.start }
    prefab_options = OpenStruct.new(sse_api_urls: ['http://localhost:4572'], sdk_key: 'k')
    config_loader = OpenStruct.new(highwater_mark: 0)
    sse_options = Quonfig::SSEConfigClient::Options.new(sse_read_timeout: 5,
                                                        sse_initial_reconnect_delay: 0.05)
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader, sse_options)

    received = 0
    client.start { |_e, _ev, _s| received += 1 }
    wait_for -> { received >= 1 }

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    client.close
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    server.stop

    assert elapsed < 3.0, "close should interrupt the in-flight stream quickly (took #{elapsed}s)"
  end

  # ---- EventParser -------------------------------------------------------

  def test_parser_dispatches_complete_event_on_blank_line
    parser = Quonfig::SSEConfigClient::EventParser.new
    events = []

    parser.feed("id: 7\n") { |e| events << e }
    parser.feed("data: #{SAMPLE_JSON_PAYLOAD}\n") { |e| events << e }
    assert_empty events, 'event should not flush until the terminating blank line'

    parser.feed("\n") { |e| events << e }
    assert_equal 1, events.size
    assert_equal '7', events.first.id
    assert_equal 'test', events.first.envelope.meta['environment']
  end

  def test_parser_ignores_comment_lines
    parser = Quonfig::SSEConfigClient::EventParser.new
    events = []
    parser.feed(":keepalive\ndata: #{SAMPLE_JSON_PAYLOAD}\n\n") { |e| events << e }
    assert_equal 1, events.size
  end

  def test_parser_concatenates_multi_line_data
    parser = Quonfig::SSEConfigClient::EventParser.new
    events = []
    json = JSON.generate({ configs: [], meta: { version: 'v', environment: 'e', note: "a\nb" } })
    lines = json.split("\n")
    # Two data: lines per SSE spec — accumulator joins with newline.
    parser.feed("data: #{lines[0]}\ndata: #{lines[1]}\n\n") { |e| events << e }
    assert_equal 1, events.size
    assert_equal "a\nb", events.first.envelope.meta['note']
  end

  def test_parser_skips_malformed_json_without_tearing_down_stream
    parser = Quonfig::SSEConfigClient::EventParser.new
    events = []
    parser.feed("data: this is not json\n\n") { |e| events << e }
    parser.feed("data: #{SAMPLE_JSON_PAYLOAD}\n\n") { |e| events << e }
    assert_equal 1, events.size, 'malformed event dropped, next valid event still delivered'

    assert_logged([/SSE Streaming Error.*malformed JSON/])
  end

  def test_parser_handles_optional_space_after_field_colon
    parser = Quonfig::SSEConfigClient::EventParser.new
    events = []
    parser.feed("data:#{SAMPLE_JSON_PAYLOAD}\n\n") { |e| events << e }
    assert_equal 1, events.size
  end

  # ---- LineReader --------------------------------------------------------

  def test_line_reader_yields_lines_split_by_lf
    reader = Quonfig::SSEConfigClient::LineReader.new
    lines = []
    reader.feed("alpha\nbeta\ngamma\n") { |l| lines << l }
    assert_equal %w[alpha beta gamma], lines
  end

  def test_line_reader_yields_lines_split_by_crlf
    reader = Quonfig::SSEConfigClient::LineReader.new
    lines = []
    reader.feed("alpha\r\nbeta\r\n") { |l| lines << l }
    assert_equal %w[alpha beta], lines
  end

  def test_line_reader_handles_mid_chunk_boundary
    reader = Quonfig::SSEConfigClient::LineReader.new
    lines = []
    reader.feed('hel') { |l| lines << l }
    reader.feed("lo\nwor") { |l| lines << l }
    reader.feed("ld\n") { |l| lines << l }
    assert_equal %w[hello world], lines
  end

  def test_line_reader_handles_crlf_split_across_chunks
    reader = Quonfig::SSEConfigClient::LineReader.new
    lines = []
    reader.feed("first\r") { |l| lines << l }
    reader.feed("\nsecond\n") { |l| lines << l }
    assert_equal %w[first second], lines
  end

  def test_line_reader_handles_multibyte_split_across_chunks
    snowman = 'snow☃man'
    bytes = snowman.b
    reader = Quonfig::SSEConfigClient::LineReader.new
    lines = []
    reader.feed(bytes[0, 5]) { |l| lines << l } # cuts the ☃ in half
    reader.feed("#{bytes[5..]}\n") { |l| lines << l }
    assert_equal 1, lines.size
    assert_equal snowman, lines.first
    assert_equal Encoding::UTF_8, lines.first.encoding
  end

  def test_line_reader_does_not_yield_trailing_partial_line
    reader = Quonfig::SSEConfigClient::LineReader.new
    lines = []
    reader.feed("complete\nincomplete-no-terminator") { |l| lines << l }
    assert_equal ['complete'], lines
  end

  # ---- WEBrick endpoints --------------------------------------------------

  def start_webrick_server(port, endpoint_class)
    log_string = StringIO.new
    logger = WEBrick::Log.new(log_string)
    server = WEBrick::HTTPServer.new(Port: port, Logger: logger, AccessLog: [])
    server.mount '/api/v2/sse', endpoint_class

    [server, log_string]
  end

  module SharedEndpointLogic
    def event_id
      @@event_id ||= 0
      @@event_id += 1
    end

    def setup_response(response)
      response.status = 200
      response['Content-Type'] = 'text/event-stream'
      response['Cache-Control'] = 'no-cache'
      response['Connection'] = 'keep-alive'

      response.chunked = false
    end
  end

  class DisconnectingEndpoint < WEBrick::HTTPServlet::AbstractServlet
    include SharedEndpointLogic

    def do_GET(_request, response)
      setup_response(response)
      response.body = "id: #{event_id}\nevent: message\ndata: #{TestSSEConfigClient::SAMPLE_JSON_PAYLOAD}\n\n"
    end
  end

  class ErroringEndpoint < WEBrick::HTTPServlet::AbstractServlet
    include SharedEndpointLogic

    NUMBER_OF_FAILURES = 5

    def do_GET(_request, response)
      setup_response(response)

      response.body = "id: #{event_id}\n"

      raise 'ErroringEndpoint' if event_id < NUMBER_OF_FAILURES

      response.body += "event: message\ndata: #{TestSSEConfigClient::SAMPLE_JSON_PAYLOAD}\n\n"
    end
  end

  class AlwaysErroringEndpoint < WEBrick::HTTPServlet::AbstractServlet
    include SharedEndpointLogic

    def do_GET(_request, _response)
      raise 'always 500'
    end
  end

  class LastEventIdEndpoint < WEBrick::HTTPServlet::AbstractServlet
    @received_ids = []
    @counter = 0
    class << self
      attr_accessor :received_ids, :counter
    end

    def do_GET(request, response)
      self.class.received_ids << request['Last-Event-Id']
      self.class.counter += 1
      response.status = 200
      response['Content-Type'] = 'text/event-stream'
      response.chunked = false
      response.body = "id: #{self.class.counter}\ndata: #{TestSSEConfigClient::SAMPLE_JSON_PAYLOAD}\n\n"
    end
  end

  class SlowEndpoint < WEBrick::HTTPServlet::AbstractServlet
    include SharedEndpointLogic

    def do_GET(_request, response)
      response.status = 200
      response['Content-Type'] = 'text/event-stream'
      response.chunked = false
      # One event then a long idle — close() should interrupt the read,
      # not wait for the server to ever send anything else.
      body = "id: 1\ndata: #{TestSSEConfigClient::SAMPLE_JSON_PAYLOAD}\n\n"
      response.body = body
    end
  end

  # qfg-i5xv: returns a configurable HTTP status code on every request.
  # Used to drive 401/403/404 terminal-classification tests and to ensure
  # the worker stops after exactly one connect attempt.
  class TerminalStatusEndpoint < WEBrick::HTTPServlet::AbstractServlet
    @status_code = 401
    @hits = 0
    class << self
      attr_accessor :status_code, :hits
    end

    def do_GET(_request, response)
      self.class.hits += 1
      response.status = self.class.status_code
      response['Content-Type'] = 'text/plain'
      response.body = "auth error #{self.class.status_code}"
    end
  end

  # qfg-i5xv: serves N healthy SSE envelopes, then on subsequent reconnects
  # returns a configurable terminal status code. Lets us verify that a healthy
  # session followed by a terminal classification still processes the healthy
  # events and then stops cleanly.
  class HealthyThenTerminalEndpoint < WEBrick::HTTPServlet::AbstractServlet
    @counter = 0
    @healthy_hits = 0
    @terminal_hits = 0
    @healthy_count = 1
    @terminal_status = 401
    class << self
      attr_accessor :counter, :healthy_hits, :terminal_hits, :healthy_count, :terminal_status
    end

    def do_GET(_request, response)
      if self.class.healthy_hits < self.class.healthy_count
        self.class.healthy_hits += 1
        response.status = 200
        response['Content-Type'] = 'text/event-stream'
        response['Cache-Control'] = 'no-cache'
        response.chunked = false
        body = +''
        5.times do
          self.class.counter += 1
          body << "id: #{self.class.counter}\ndata: #{TestSSEConfigClient::SAMPLE_JSON_PAYLOAD}\n\n"
        end
        response.body = body
      else
        self.class.terminal_hits += 1
        response.status = self.class.terminal_status
        response['Content-Type'] = 'text/plain'
        response.body = "auth error #{self.class.terminal_status}"
      end
    end
  end
end
