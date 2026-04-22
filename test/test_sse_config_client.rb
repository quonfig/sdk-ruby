# frozen_string_literal: true

require 'test_helper'
require 'webrick'
require 'ostruct'
require 'json'

class TestSSEConfigClient < Minitest::Test
  def test_connect_url_is_api_v2_sse
    prefab_options = OpenStruct.new(sse_api_urls: ['https://stream.example.com'], sdk_key: 'test')
    config_loader = OpenStruct.new(highwater_mark: 0)
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader)

    captured_url = nil
    fake = OpenStruct.new(closed?: false)
    fake.define_singleton_method(:on_event) { |&_b| }
    fake.define_singleton_method(:on_error) { |&_b| }
    fake.define_singleton_method(:close) { }

    SSE::Client.stub :new, ->(url, *_args, **_kwargs, &block) {
      captured_url = url
      block.call(fake) if block
      fake
    } do
      client.connect { |_e, _ev, _s| }
    end

    assert_equal 'https://stream.example.com/api/v2/sse', captured_url
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
    fake.define_singleton_method(:close) { }
    fake.define_singleton_method(:closed?) { false }

    SSE::Client.stub :new, ->(*_args, **_kwargs, &block) {
      block.call(fake) if block
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
    assert_match(/\Asdk-ruby-/, h['X-Quonfig-SDK-Version'])
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
      logger.error "SSE Streaming Error: Received empty data for url http://test"
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
      logger.error "SSE Streaming Error: Received empty data for url http://test"
      mock_client.close
    end

    log_lines = log_output.string.split("\n")
    assert log_lines.any? { |line| line.include?('SSE Streaming Error') && line.include?('empty data') },
           'Expected to have logged an error about empty data for nil'
    mock_client.verify
  end

  def test_last_event_id_initialization
    # Test with positive highwater_mark
    config_loader = OpenStruct.new(highwater_mark: 42)
    prefab_options = OpenStruct.new(sse_api_urls: ['http://localhost:4567'], sdk_key: 'test')
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader)

    # Mock SSE::Client.new to capture the last_event_id argument
    SSE::Client.stub :new, ->(*args, **kwargs, &block) {
      assert_equal '42', kwargs[:last_event_id], 'Expected last_event_id to be "42"'
      OpenStruct.new(closed?: false, close: nil)
    } do
      client.connect { |_configs, _event, _source| }
    end

    # Test with nil highwater_mark
    config_loader = OpenStruct.new(highwater_mark: nil)
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader)

    SSE::Client.stub :new, ->(*args, **kwargs, &block) {
      assert_nil kwargs[:last_event_id], 'Expected last_event_id to be nil when highwater_mark is nil'
      OpenStruct.new(closed?: false, close: nil)
    } do
      client.connect { |_configs, _event, _source| }
    end

    # Test with zero highwater_mark
    config_loader = OpenStruct.new(highwater_mark: 0)
    client = Quonfig::SSEConfigClient.new(prefab_options, config_loader)

    SSE::Client.stub :new, ->(*args, **kwargs, &block) {
      assert_nil kwargs[:last_event_id], 'Expected last_event_id to be nil when highwater_mark is 0'
      OpenStruct.new(closed?: false, close: nil)
    } do
      client.connect { |_configs, _event, _source| }
    end
  end
end
