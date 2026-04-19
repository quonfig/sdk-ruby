# frozen_string_literal: true

module Quonfig
  class HttpConnection
    AUTH_USER = 'authuser'
    PROTO_HEADERS = {
      'Content-Type' => 'application/x-protobuf',
      'Accept' => 'application/x-protobuf',
      'X-Quonfig-SDK-Version' => "sdk-ruby-#{Quonfig::VERSION}"
    }.freeze

    def initialize(uri, sdk_key)
      @uri = uri
      @sdk_key = sdk_key
    end

    def uri
      @uri
    end

    def get(path, headers = {})
      connection(PROTO_HEADERS.merge(headers)).get(path)
    end

    def post(path, body)
      connection(PROTO_HEADERS).post(path, body.to_proto)
    end

    def connection(headers = {})
      if Faraday::VERSION[0].to_i >= 2
        Faraday.new(@uri) do |conn|
          conn.request :authorization, :basic, AUTH_USER, @sdk_key

          conn.headers.merge!(headers)
        end
      else
        Faraday.new(@uri) do |conn|
          conn.request :basic_auth, AUTH_USER, @sdk_key

          conn.headers.merge!(headers)
        end
      end
    end
  end
end
