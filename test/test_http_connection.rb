# frozen_string_literal: true

require 'test_helper'
require 'base64'
require 'json'

module Quonfig
  class HttpConnectionTest < Minitest::Test
    URI = 'https://primary.quonfig.com'
    SDK_KEY = 'abc.def.123'

    def test_uses_basic_auth_with_username_1
      conn = HttpConnection.new(URI, SDK_KEY).connection
      expected = 'Basic ' + Base64.strict_encode64("1:#{SDK_KEY}")
      assert_equal expected, conn.headers['Authorization']
    end

    def test_json_content_type_and_accept_headers
      conn = HttpConnection.new(URI, SDK_KEY).connection
      assert_equal 'application/json', conn.headers['Content-Type']
      assert_equal 'application/json', conn.headers['Accept']
    end

    def test_x_quonfig_sdk_version_header
      conn = HttpConnection.new(URI, SDK_KEY).connection
      assert_equal "ruby-#{Quonfig::VERSION}", conn.headers['X-Quonfig-SDK-Version']
    end

    def test_no_protobuf_content_type
      conn = HttpConnection.new(URI, SDK_KEY).connection
      refute_equal 'application/x-protobuf', conn.headers['Content-Type']
      refute_equal 'application/x-protobuf', conn.headers['Accept']
    end

    def test_post_serializes_body_as_json
      stubs = Faraday::Adapter::Test::Stubs.new
      captured_body = nil
      captured_content_type = nil
      stubs.post('/telemetry') do |env|
        captured_body = env.body
        captured_content_type = env.request_headers['Content-Type']
        [200, {}, '']
      end

      http = HttpConnection.new(URI, SDK_KEY)
      http.define_singleton_method(:connection) do |headers = {}|
        Faraday.new(URI) do |conn|
          conn.headers.merge!(HttpConnection::JSON_HEADERS.merge(headers))
          conn.adapter :test, stubs
        end
      end

      body = { hello: 'world', n: 3 }
      http.post('/telemetry', body)

      assert_equal 'application/json', captured_content_type
      assert_equal body.to_json, captured_body
      stubs.verify_stubbed_calls
    end
  end

  class OptionsDefaultApiUrlsTest < Minitest::Test
    def test_default_api_urls_use_quonfig_domain
      assert_includes Options::DEFAULT_API_URLS, 'https://primary.quonfig.com'
      refute(Options::DEFAULT_API_URLS.any? { |s| s.include?('reforge.com') })
    end

    def test_telemetry_destination_honors_quonfig_telemetry_url_env
      with_env('QUONFIG_TELEMETRY_URL', 'https://override-telemetry.example.com') do
        assert_equal 'https://override-telemetry.example.com',
                     Options.new.telemetry_destination
      end
    end

    def test_telemetry_destination_default
      assert_equal 'https://telemetry.quonfig.com', Options.new.telemetry_destination
    end
  end
end
