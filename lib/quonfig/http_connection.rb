# frozen_string_literal: true

require 'base64'
require 'json'

module Quonfig
  class HttpConnection
    SDK_VERSION = "ruby-#{Quonfig::VERSION}".freeze

    JSON_HEADERS = {
      'Content-Type' => 'application/json',
      'Accept' => 'application/json',
      'X-Quonfig-SDK-Version' => SDK_VERSION
    }.freeze

    def initialize(uri, sdk_key)
      @uri = uri
      @sdk_key = sdk_key
    end

    def uri
      @uri
    end

    def get(path, headers = {})
      connection(headers).get(path)
    end

    def post(path, body)
      connection.post(path, body.to_json)
    end

    def connection(headers = {})
      merged = JSON_HEADERS.merge('Authorization' => auth_header).merge(headers)
      Faraday.new(@uri) do |conn|
        conn.headers.merge!(merged)
      end
    end

    private

    def auth_header
      'Basic ' + Base64.strict_encode64("1:#{@sdk_key}")
    end
  end
end
