# frozen_string_literal: true
require 'base64'
require 'json'

module Quonfig
  class SSEConfigClient
    class Options
      attr_reader :sse_read_timeout, :seconds_between_new_connection,
                  :sse_default_reconnect_time, :sleep_delay_for_new_connection_check,
                  :errors_to_close_connection

      def initialize(sse_read_timeout: 300,
                     seconds_between_new_connection: 5,
                     sleep_delay_for_new_connection_check: 1,
                     sse_default_reconnect_time: SSE::Client::DEFAULT_RECONNECT_TIME,
                     errors_to_close_connection: [HTTP::ConnectionError])
        @sse_read_timeout = sse_read_timeout
        @seconds_between_new_connection = seconds_between_new_connection
        @sse_default_reconnect_time = sse_default_reconnect_time
        @sleep_delay_for_new_connection_check = sleep_delay_for_new_connection_check
        @errors_to_close_connection = errors_to_close_connection
      end
    end

    LOG = Quonfig::InternalLogger.new(self)

    def initialize(prefab_options, config_loader, options = nil, logger = nil)
      @prefab_options = prefab_options
      @options = options || Options.new
      @config_loader = config_loader
      @connected = false
      @logger = logger || LOG
    end

    def close
      @retry_thread&.kill
      @client&.close
    end

    def start(&load_configs)
      if @prefab_options.sse_api_urls.empty?
        @logger.debug 'No SSE api_urls configured'
        return
      end

      @client = connect(&load_configs)

      closed_count = 0

      @retry_thread = Thread.new do
        loop do
          sleep @options.sleep_delay_for_new_connection_check

          if @client.closed?
            closed_count += @options.sleep_delay_for_new_connection_check

            if closed_count > @options.seconds_between_new_connection
              closed_count = 0
              @logger.debug 'Reconnecting SSE client'
              @client = connect(&load_configs)
            end
          end
        end
      end
    end

    def connect(&load_configs)
      url = "#{source}/api/v2/sse/config"
      @logger.debug "SSE Streaming Connect to #{url} start_at #{@config_loader.highwater_mark}"

      SSE::Client.new(url,
                      headers: headers,
                      read_timeout: @options.sse_read_timeout,
                      reconnect_time: @options.sse_default_reconnect_time,
                      last_event_id: (@config_loader.highwater_mark&.positive? ? @config_loader.highwater_mark.to_s : nil),
                      logger: Quonfig::InternalLogger.new(SSE::Client)) do |client|
        client.on_event do |event|
          if event.data.nil? || event.data.empty?
            @logger.error "SSE Streaming Error: Received empty data for url #{url}"
            client.close
            return
          end

          begin
            parsed = JSON.parse(event.data)
          rescue JSON::ParserError => e
            @logger.error "SSE Streaming Error: Failed to parse JSON for url #{url}: #{e.message}"
            client.close
            return
          end

          envelope = Quonfig::ConfigEnvelope.new(
            configs: parsed['configs'] || [],
            meta: parsed['meta'] || {}
          )
          load_configs.call(envelope, event, :sse)
        end

        client.on_error do |error|
          # SSL "unexpected eof" is expected when SSE sessions timeout normally
          if error.is_a?(OpenSSL::SSL::SSLError) && error.message.include?('unexpected eof')
            @logger.debug "SSE Streaming: Connection closed (expected timeout) for url #{url}"
          else
            @logger.error "SSE Streaming Error: #{error.inspect} for url #{url}"
          end

          if @options.errors_to_close_connection.any? { |klass| error.is_a?(klass) }
            @logger.debug "Closing SSE connection for url #{url}"
            client.close
          end
        end
      end
    end

    def headers
      auth = "1:#{@prefab_options.sdk_key}"
      auth_string = Base64.strict_encode64(auth)
      return {
        'Authorization' => "Basic #{auth_string}",
        'Accept' => 'text/event-stream',
        'X-Quonfig-SDK-Version' => "sdk-ruby-#{Quonfig::VERSION}"
      }
    end

    def source
      @source_index = @source_index.nil? ? 0 : @source_index + 1

      if @source_index >= @prefab_options.sse_api_urls.size
        @source_index = 0
      end

      @prefab_options.sse_api_urls[@source_index]
    end
  end
end
