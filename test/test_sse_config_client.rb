# frozen_string_literal: true

require 'test_helper'
require 'webrick'
require 'ostruct'
require 'json'

class TestSSEConfigClient < Minitest::Test
  def test_default_sse_read_timeout_is_90_seconds
    # qfg-47c2.9: Layer 1 retune — read deadline 300s -> 90s so a silent SSE
    # stall trips within 3x the 30s server heartbeat instead of after 5 minutes.
    opts = Quonfig::SSEConfigClient::Options.new
    assert_equal 90, opts.sse_read_timeout
  end

  # qfg-ie49: ld-eventsource's backoff only resets after a connection has been
  # healthy for `reconnect_reset_interval` seconds (default 60s). Under chaos
  # scenario 09 (proxy flaps every 6s) a 60s reset means the backoff runs away
  # and the SDK sleeps through later kills. We override it to 1s.
  def test_sse_reconnect_reset_interval_defaults_to_one_second
    opts = Quonfig::SSEConfigClient::Options.new
    assert_equal 1, opts.sse_reconnect_reset_interval
  end

  def test_connect_passes_reconnect_reset_interval_to_sse_client
    prefab_options = OpenStruct.new(sse_api_urls: ['https://stream.example.com'], sdk_key: 'test')
    config_loader = OpenStruct.new(highwater_mark: 0)
    sse_options = Quonfig::SSEConfigClient::Options.new(sse_reconnect_reset_interval: 3)
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader, sse_options)

    captured_kwargs = nil
    SSE::Client.stub :new, lambda { |*_args, **kwargs|
      captured_kwargs = kwargs
      OpenStruct.new(closed?: false, close: nil)
    } do
      client.connect { |_e, _ev, _s| }
    end

    assert_equal 3, captured_kwargs[:reconnect_reset_interval]
  end

  def test_connect_url_is_api_v2_sse_config
    prefab_options = OpenStruct.new(sse_api_urls: ['https://stream.example.com'], sdk_key: 'test')
    config_loader = OpenStruct.new(highwater_mark: 0)
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader)

    captured_url = nil
    fake = OpenStruct.new(closed?: false)
    fake.define_singleton_method(:on_event) { |&_b| }
    fake.define_singleton_method(:on_error) { |&_b| }
    fake.define_singleton_method(:close) {}

    SSE::Client.stub :new, lambda { |url, *_args, **_kwargs, &block|
      captured_url = url
      block&.call(fake)
      fake
    } do
      client.connect { |_e, _ev, _s| }
    end

    assert_equal 'https://stream.example.com/api/v2/sse/config', captured_url
  end

  def test_on_event_parses_json_into_config_envelope
    prefab_options = OpenStruct.new(sse_api_urls: ['https://stream.example.com'], sdk_key: 'test')
    config_loader = OpenStruct.new(highwater_mark: 0)
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader)

    captured = {}
    event_handler = nil
    fake = Object.new
    fake.define_singleton_method(:on_event) { |&block| event_handler = block }
    fake.define_singleton_method(:on_error) { |&_b| }
    fake.define_singleton_method(:close) {}
    fake.define_singleton_method(:closed?) { false }

    SSE::Client.stub :new, lambda { |*_args, **_kwargs, &block|
      block&.call(fake)
      fake
    } do
      client.connect do |envelope, event, source|
        captured[:envelope] = envelope
        captured[:event] = event
        captured[:source] = source
      end
    end

    json_data = JSON.generate({
                                configs: [{ key: 'my.key', valueType: 'string', default: { rules: [] } }],
                                meta: { version: 'abc123', environment: 'prod' }
                              })

    event_handler.call(OpenStruct.new(data: json_data))

    assert_instance_of Quonfig::ConfigEnvelope, captured[:envelope]
    assert_equal 1, captured[:envelope].configs.length
    assert_equal 'my.key', captured[:envelope].configs[0]['key']
    assert_equal 'abc123', captured[:envelope].meta['version']
    assert_equal :sse, captured[:source]
  end

  def test_headers_basic_auth_uses_1_prefix
    prefab_options = OpenStruct.new(sse_api_urls: ['https://stream.example.com'], sdk_key: 'mykey')
    config_loader = OpenStruct.new(highwater_mark: 0)
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader)

    h = client.headers

    assert_equal "Basic #{Base64.strict_encode64('1:mykey')}", h['Authorization']
    assert_match(/\Aruby-\d+\.\d+\.\d+/, h['X-Quonfig-SDK-Version'])
    refute h.key?('X-Reforge-SDK-Version')
  end

  def test_recovering_from_disconnection
    server, = start_webrick_server(4567, DisconnectingEndpoint)

    config_loader = OpenStruct.new(highwater_mark: 4)

    prefab_options = OpenStruct.new(sse_api_urls: ['http://localhost:4567'], sdk_key: 'test')
    last_event_id = nil
    client = nil

    begin
      Thread.new do
        server.start
      end

      sse_options = Quonfig::SSEConfigClient::Options.new(
        sse_default_reconnect_time: 0.1
      )
      client = Quonfig::SSEConfigClient.new(prefab_options, config_loader, sse_options)

      client.start do |_configs, event, _source|
        last_event_id = event.id.to_i
      end

      wait_for -> { last_event_id && last_event_id > 1 }
    ensure
      client.close
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
      Thread.new do
        server.start
      end

      sse_options = Quonfig::SSEConfigClient::Options.new(
        sse_default_reconnect_time: 0.1,
        seconds_between_new_connection: 0.1,
        sleep_delay_for_new_connection_check: 0.1,
        errors_to_close_connection: [SSE::Errors::HTTPStatusError]
      )
      client = Quonfig::SSEConfigClient.new(prefab_options, config_loader, sse_options, logger)

      client.start do |_configs, event, _source|
        last_event_id = event.id.to_i
      end

      wait_for -> { last_event_id && last_event_id > 2 }
    ensure
      server.stop
      client.close

      refute_nil last_event_id, 'Expected to have received an event'
      assert last_event_id > 2, 'Expected to have received multiple events (indicating a reconnect)'
    end

    log_lines = log_output.string.split("\n")

    assert_match(/SSE Streaming Connect/, log_lines[0])
    assert_match(/SSE Streaming Error/, log_lines[1], 'Expected to have logged an error. If this starts failing after an ld-eventsource upgrade, you might need to tweak NUMBER_OF_FAILURES below')
    assert_match(/Closing SSE connection/, log_lines[2])
    assert_match(/Reconnecting SSE client/, log_lines[3])
    assert_match(/SSE Streaming Connect/, log_lines[4])
  end

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

  SAMPLE_JSON_PAYLOAD = '{"configs":[],"meta":{"version":"1","environment":"test"}}'

  class DisconnectingEndpoint < WEBrick::HTTPServlet::AbstractServlet
    include SharedEndpointLogic

    def do_GET(_request, response)
      setup_response(response)

      output = response.body

      output << "id: #{event_id}\n"
      output << "event: message\n"
      output << "data: #{SAMPLE_JSON_PAYLOAD}\n\n"
    end
  end

  class ErroringEndpoint < WEBrick::HTTPServlet::AbstractServlet
    include SharedEndpointLogic

    NUMBER_OF_FAILURES = 5

    def do_GET(_request, response)
      setup_response(response)

      output = response.body

      output << "id: #{event_id}\n"

      if event_id < NUMBER_OF_FAILURES
        raise 'ErroringEndpoint' # This manifests as an SSE::Errors::HTTPStatusError
      end

      output << "event: message\n"
      output << "data: #{SAMPLE_JSON_PAYLOAD}\n\n"
    end
  end

  def test_empty_data_validation
    # Unit test to verify that empty data is properly detected and handled
    log_output = StringIO.new
    logger = Logger.new(log_output)

    # Test that empty event.data is detected
    mock_event = OpenStruct.new(data: '')
    mock_client = Minitest::Mock.new
    mock_client.expect(:close, nil)

    # Simulate the on_event handler logic
    if mock_event.data.nil? || mock_event.data.empty?
      logger.error 'SSE Streaming Error: Received empty data for url http://test'
      mock_client.close
    end

    log_lines = log_output.string.split("\n")
    assert log_lines.any? { |line| line.include?('SSE Streaming Error') && line.include?('empty data') },
           'Expected to have logged an error about empty data'
    mock_client.verify

    # Test that nil event.data is detected
    log_output = StringIO.new
    logger = Logger.new(log_output)
    mock_event = OpenStruct.new(data: nil)
    mock_client = Minitest::Mock.new
    mock_client.expect(:close, nil)

    if mock_event.data.nil? || mock_event.data.empty?
      logger.error 'SSE Streaming Error: Received empty data for url http://test'
      mock_client.close
    end

    log_lines = log_output.string.split("\n")
    assert log_lines.any? { |line| line.include?('SSE Streaming Error') && line.include?('empty data') },
           'Expected to have logged an error about empty data for nil'
    mock_client.verify
  end

  # qfg-47c2.27: on_error must call back into the parent client so
  # connection_state can transition :connected -> :error.
  def test_on_error_invokes_error_callback
    prefab_options = OpenStruct.new(sse_api_urls: ['https://stream.example.com'], sdk_key: 'test')
    config_loader = OpenStruct.new(highwater_mark: 0)

    errors_seen = []
    client = Quonfig::SSEConfigClient.new(
      prefab_options,
      config_loader,
      nil,
      nil,
      on_error: ->(err) { errors_seen << err }
    )

    error_handler = nil
    fake = Object.new
    fake.define_singleton_method(:on_event) { |&_b| }
    fake.define_singleton_method(:on_error) { |&block| error_handler = block }
    fake.define_singleton_method(:close) {}
    fake.define_singleton_method(:closed?) { false }

    SSE::Client.stub :new, lambda { |*_args, **_kwargs, &block|
      block&.call(fake)
      fake
    } do
      client.connect { |_e, _ev, _s| }
    end

    refute_nil error_handler, 'on_error block must be registered'
    err = HTTP::ConnectionError.new('boom')
    error_handler.call(err)

    assert_equal 1, errors_seen.size, 'on_error callback must be invoked once per error'
    assert_same err, errors_seen.first

    assert_logged([/SSE Streaming Error.*HTTP::ConnectionError/])
  end

  def test_on_error_callback_fires_for_unexpected_errors_too
    # Even non-connection-closing errors (e.g. a transient SSE protocol error
    # that we log but don't close on) must still notify the parent client so
    # @sse_state reflects the disconnect edge accurately.
    prefab_options = OpenStruct.new(sse_api_urls: ['https://stream.example.com'], sdk_key: 'test')
    config_loader = OpenStruct.new(highwater_mark: 0)

    errors_seen = []
    client = Quonfig::SSEConfigClient.new(
      prefab_options,
      config_loader,
      nil,
      nil,
      on_error: ->(err) { errors_seen << err }
    )

    error_handler = nil
    fake = Object.new
    fake.define_singleton_method(:on_event) { |&_b| }
    fake.define_singleton_method(:on_error) { |&block| error_handler = block }
    fake.define_singleton_method(:close) {}
    fake.define_singleton_method(:closed?) { false }

    SSE::Client.stub :new, lambda { |*_args, **_kwargs, &block|
      block&.call(fake)
      fake
    } do
      client.connect { |_e, _ev, _s| }
    end

    error_handler.call(StandardError.new('unexpected'))

    assert_equal 1, errors_seen.size

    assert_logged([/SSE Streaming Error.*StandardError.*unexpected/])
  end

  # qfg-ll6r / qfg-ie49: chaos scenario 09 requires the SDK to surface a
  # Layer 1 (SSE) worker_restart_total counter so kill-storm scenarios can be
  # measured. restart_total counts every *reconnect*, not every error edge:
  # ld-eventsource auto-reconnects on a clean socket EOF (server FIN) without
  # ever calling on_error, so counting on_error alone misses the flapping case
  # scenario 09 models (qfg-ie49).
  def test_restart_total_starts_at_zero
    prefab_options = OpenStruct.new(sse_api_urls: ['https://stream.example.com'], sdk_key: 'test')
    config_loader = OpenStruct.new(highwater_mark: 0)
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader)
    assert_equal 0, client.restart_total
  end

  # qfg-ie49 regression: a clean server-side FIN (the chaos scenario 09 "kill
  # the proxy for 200ms" shape) makes ld-eventsource reconnect *internally*
  # without ever firing on_error. restart_total must still observe those
  # reconnects — otherwise the kill-storm scenario asserts >= 5 and gets 0.
  # Self-contained endpoint with its own event counter — deliberately NOT
  # using SharedEndpointLogic's @@event_id, which is shared across every
  # endpoint class and would make this test pollute test_recovering_from_*.
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
                      "data: #{SAMPLE_JSON_PAYLOAD}\n\n"
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

      sse_options = Quonfig::SSEConfigClient::Options.new(
        sse_default_reconnect_time: 0.1
      )
      client = Quonfig::SSEConfigClient.new(prefab_options, config_loader, sse_options)

      client.start do |_configs, event, _source|
        last_event_id = event.id.to_i
      end

      # >3 distinct event ids means DisconnectingEndpoint served the stream,
      # FIN'd, and ld-eventsource reconnected at least 3 times.
      wait_for -> { last_event_id && last_event_id > 3 }
    ensure
      client&.close
      server.stop
    end

    assert client.restart_total >= 3,
           'restart_total must count ld-eventsource internal reconnects on a ' \
           "clean FIN (got #{client.restart_total})"
  end

  # The hook is ld-eventsource's per-reconnect "Will retry connection after"
  # info log — the only signal it emits for an internal reconnect. Drive that
  # log line directly through the logger SSEConfigClient hands to SSE::Client.
  def test_restart_total_counts_ld_eventsource_reconnect_signal
    prefab_options = OpenStruct.new(sse_api_urls: ['https://stream.example.com'], sdk_key: 'test')
    config_loader = OpenStruct.new(highwater_mark: 0)
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader)

    captured_logger = nil
    fake = Object.new
    fake.define_singleton_method(:on_event) { |&_b| }
    fake.define_singleton_method(:on_error) { |&_b| }
    fake.define_singleton_method(:close) {}
    fake.define_singleton_method(:closed?) { false }

    SSE::Client.stub :new, lambda { |*_args, **kwargs, &block|
      captured_logger = kwargs[:logger]
      block&.call(fake)
      fake
    } do
      client.connect { |_e, _ev, _s| }
    end

    refute_nil captured_logger, 'SSEConfigClient must hand a logger to SSE::Client'
    assert_equal 0, client.restart_total

    # The initial "Connecting to event stream" line is not a reconnect.
    captured_logger.info { 'Connecting to event stream at https://stream.example.com' }
    assert_equal 0, client.restart_total

    captured_logger.info { 'Will retry connection after 0.500 seconds' }
    captured_logger.info { 'Will retry connection after 1.000 seconds' }
    assert_equal 2, client.restart_total,
                 'each ld-eventsource reconnect signal must bump restart_total'
  end

  # on_error still notifies the parent client (connection_state wiring) but is
  # NO LONGER a restart_total source — that would double-count every
  # non-closing error, which ld-eventsource also reconnects internally.
  def test_on_error_does_not_increment_restart_total
    prefab_options = OpenStruct.new(sse_api_urls: ['https://stream.example.com'], sdk_key: 'test')
    config_loader = OpenStruct.new(highwater_mark: 0)
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader)

    error_handler = nil
    fake = Object.new
    fake.define_singleton_method(:on_event) { |&_b| }
    fake.define_singleton_method(:on_error) { |&block| error_handler = block }
    fake.define_singleton_method(:close) {}
    fake.define_singleton_method(:closed?) { false }

    SSE::Client.stub :new, lambda { |*_args, **_kwargs, &block|
      block&.call(fake)
      fake
    } do
      client.connect { |_e, _ev, _s| }
    end

    refute_nil error_handler
    3.times { |i| error_handler.call(StandardError.new("err-#{i}")) }

    assert_equal 0, client.restart_total,
                 'on_error edges must not bump restart_total (reconnects are counted instead)'
    assert_logged([/SSE Streaming Error/])
  end

  def test_last_event_id_initialization
    # Test with positive highwater_mark
    config_loader = OpenStruct.new(highwater_mark: 42)
    prefab_options = OpenStruct.new(sse_api_urls: ['http://localhost:4567'], sdk_key: 'test')
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader)

    # Mock SSE::Client.new to capture the last_event_id argument
    SSE::Client.stub :new, lambda { |*_args, **kwargs|
      assert_equal '42', kwargs[:last_event_id], 'Expected last_event_id to be "42"'
      OpenStruct.new(closed?: false, close: nil)
    } do
      client.connect { |_configs, _event, _source| }
    end

    # Test with nil highwater_mark
    config_loader = OpenStruct.new(highwater_mark: nil)
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader)

    SSE::Client.stub :new, lambda { |*_args, **kwargs|
      assert_nil kwargs[:last_event_id], 'Expected last_event_id to be nil when highwater_mark is nil'
      OpenStruct.new(closed?: false, close: nil)
    } do
      client.connect { |_configs, _event, _source| }
    end

    # Test with zero highwater_mark
    config_loader = OpenStruct.new(highwater_mark: 0)
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader)

    SSE::Client.stub :new, lambda { |*_args, **kwargs|
      assert_nil kwargs[:last_event_id], 'Expected last_event_id to be nil when highwater_mark is 0'
      OpenStruct.new(closed?: false, close: nil)
    } do
      client.connect { |_configs, _event, _source| }
    end
  end

  # qfg-cf52: ld-eventsource calls the logger we hand it from inside its
  # bare-Thread `run_stream` loop, and several of those call sites
  # (`connect`, `log_and_dispatch_error`, `build_uri_with_query_params`) are
  # NOT wrapped in a rescue. If our ReconnectCountingLogger ever raises, the
  # exception escapes `run_stream`, the worker thread dies, and `@stopped`
  # stays false forever — `closed?` never flips true so the SDK's
  # @retry_thread never reconnects. The logger wrapper must therefore be
  # raise-proof: a throwing wrapped logger, a throwing message block, or a
  # throwing on_reconnect callback must never propagate out.
  Reconnect = Quonfig::SSEConfigClient::ReconnectCountingLogger

  def test_reconnect_counting_logger_swallows_wrapped_logger_exceptions
    boom = Object.new
    Reconnect::LEVELS.each do |lvl|
      boom.define_singleton_method(lvl) { |*_a, &_b| raise 'wrapped logger blew up' }
    end
    boom.define_singleton_method(:respond_to?) { |*_a| true }

    logger = Reconnect.new(boom) { nil }

    Reconnect::LEVELS.each do |lvl|
      logger.public_send(lvl, 'hello')
      logger.public_send(lvl) { 'lazy message' }
    end
  end

  def test_reconnect_counting_logger_swallows_on_reconnect_exceptions
    logger = Reconnect.new(nil) { raise 'on_reconnect blew up' }

    # The reconnect signal at info level is what triggers @on_reconnect.
    logger.info('Will retry connection after 1.000 seconds')
  end

  def test_reconnect_counting_logger_swallows_message_block_exceptions
    logger = Reconnect.new(nil) { nil }

    logger.info { raise 'message block blew up' }
  end

  def test_reconnect_counting_logger_still_counts_when_wrapped_logger_raises
    boom = Object.new
    Reconnect::LEVELS.each do |lvl|
      boom.define_singleton_method(lvl) { |*_a, &_b| raise 'wrapped logger blew up' }
    end
    boom.define_singleton_method(:respond_to?) { |*_a| true }

    count = 0
    logger = Reconnect.new(boom) { count += 1 }

    logger.info('Will retry connection after 1.000 seconds')

    assert_equal 1, count,
                 'a throwing wrapped logger must not stop the reconnect counter from firing'
  end
end
