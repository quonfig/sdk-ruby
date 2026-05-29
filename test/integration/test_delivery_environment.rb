# frozen_string_literal: true

# AUTO-GENERATED from integration-test-data/tests/eval/delivery_environment.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'webrick'
require 'json'
require 'socket'

class TestDeliveryEnvironment < Minitest::Test
  # Stand up a WEBrick server returning the literal wire envelope on
  # /api/v2/configs (the shape api-delivery emits in SDK-key mode).
  def start_delivery_server(envelope_json)
    log = WEBrick::Log.new(StringIO.new)
    server = WEBrick::HTTPServer.new(Port: 0, Logger: log, AccessLog: [])
    server.mount_proc '/api/v2/configs' do |_req, res|
      res.status = 200
      res['Content-Type'] = 'application/json'
      res['ETag'] = '"v1"'
      res.body = envelope_json
    end
    port = server.config[:Port]
    Thread.new { server.start }
    50.times do
      break if tcp_open?(port)

      sleep 0.05
    end
    [server, port]
  end

  def tcp_open?(port)
    TCPSocket.new('127.0.0.1', port).tap(&:close)
    true
  rescue StandardError
    false
  end

  # singular environment override wins over default when env not pinned
  def test_singular_environment_override_wins_over_default_when_env_not_pinned
    prev_env = ENV.delete('QUONFIG_ENVIRONMENT')
    envelope_json = '{"meta":{"version":"v1","environment":"development"},"configs":[{"id":"c-env","key":"flag.env-scoped","type":"bool","valueType":"bool","sendToClientSdk":false,"default":{"rules":[{"criteria":[{"operator":"ALWAYS_TRUE"}],"value":{"type":"bool","value":true}}]},"environment":{"id":"development","rules":[{"criteria":[{"operator":"ALWAYS_TRUE"}],"value":{"type":"bool","value":false}}]}}]}'
    server, port = start_delivery_server(envelope_json)
    client = Quonfig::Client.new(
      sdk_key: 'sdk-test',
      api_urls: ["http://127.0.0.1:#{port}"],
      enable_sse: false,
      enable_polling: false,
      context_upload_mode: :none,
      collect_evaluation_summaries: false
    )
    assert_equal false, client.get('flag.env-scoped', :missing),
                 'delivery-wire env override: expected false for flag.env-scoped'
  ensure
    client&.stop
    server&.shutdown
    ENV['QUONFIG_ENVIRONMENT'] = prev_env if prev_env
  end

  # explicit environment pin is ignored in delivery mode (meta.environment authoritative)
  def test_explicit_environment_pin_is_ignored_in_delivery_mode_meta_environment_authoritative
    prev_env = ENV.delete('QUONFIG_ENVIRONMENT')
    envelope_json = '{"meta":{"version":"v1","environment":"development"},"configs":[{"id":"c-env","key":"flag.env-scoped","type":"bool","valueType":"bool","sendToClientSdk":false,"default":{"rules":[{"criteria":[{"operator":"ALWAYS_TRUE"}],"value":{"type":"bool","value":true}}]},"environment":{"id":"development","rules":[{"criteria":[{"operator":"ALWAYS_TRUE"}],"value":{"type":"bool","value":false}}]}}]}'
    server, port = start_delivery_server(envelope_json)
    client = Quonfig::Client.new(
      sdk_key: 'sdk-test',
      api_urls: ["http://127.0.0.1:#{port}"],
      enable_sse: false,
      enable_polling: false,
      context_upload_mode: :none,
      collect_evaluation_summaries: false,
      environment: 'staging'
    )
    assert_equal false, client.get('flag.env-scoped', :missing),
                 'delivery-wire env override: expected false for flag.env-scoped'
    assert_logged([/was set but the client is in delivery \(SDK-key\) mode/])
  ensure
    client&.stop
    server&.shutdown
    ENV['QUONFIG_ENVIRONMENT'] = prev_env if prev_env
  end

  # config without environment block falls back to default in delivery mode
  def test_config_without_environment_block_falls_back_to_default_in_delivery_mode
    prev_env = ENV.delete('QUONFIG_ENVIRONMENT')
    envelope_json = '{"meta":{"version":"v1","environment":"development"},"configs":[{"id":"c-def","key":"flag.default-only","type":"bool","valueType":"bool","sendToClientSdk":false,"default":{"rules":[{"criteria":[{"operator":"ALWAYS_TRUE"}],"value":{"type":"bool","value":true}}]}}]}'
    server, port = start_delivery_server(envelope_json)
    client = Quonfig::Client.new(
      sdk_key: 'sdk-test',
      api_urls: ["http://127.0.0.1:#{port}"],
      enable_sse: false,
      enable_polling: false,
      context_upload_mode: :none,
      collect_evaluation_summaries: false
    )
    assert_equal true, client.get('flag.default-only', :missing),
                 'delivery-wire env override: expected true for flag.default-only'
  ensure
    client&.stop
    server&.shutdown
    ENV['QUONFIG_ENVIRONMENT'] = prev_env if prev_env
  end
end
