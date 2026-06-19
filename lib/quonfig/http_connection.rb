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

    # +timeout_ms+ (qfg-7h5d.1.9): per-request bound applied to BOTH the connect
    # (open) and read phases of every request made through this connection. nil
    # leaves Faraday's defaults (no timeout) in place — preserving the prior
    # behavior for callers that don't pass one. The config-fetch path passes
    # Options#config_fetch_timeout_ms so a hung upstream (accepts the TCP
    # connection but never responds) aborts fast instead of blocking the caller's
    # whole init budget.
    def initialize(uri, sdk_key, timeout_ms: nil)
      @uri = uri
      @sdk_key = sdk_key
      @timeout_ms = timeout_ms
    end

    attr_reader :uri

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
        if @timeout_ms
          seconds = @timeout_ms / 1000.0
          # open_timeout bounds the TCP connect; timeout bounds the read. A
          # 'timeout' toxic accepts the connection but never sends bytes, so the
          # read deadline is the one that fires — set both so a refused/slow
          # connect is bounded too.
          conn.options.open_timeout = seconds
          conn.options.timeout = seconds
        end
      end
    end

    private

    def auth_header
      "Basic #{Base64.strict_encode64("1:#{@sdk_key}")}"
    end
  end
end
