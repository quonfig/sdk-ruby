# frozen_string_literal: true

require 'base64'
require 'json'

module Quonfig
  class SSEConfigClient
    class Options
      attr_reader :sse_read_timeout, :seconds_between_new_connection,
                  :sse_default_reconnect_time, :sleep_delay_for_new_connection_check,
                  :errors_to_close_connection

      # sse_read_timeout: 90s = 3x the 30s server heartbeat. A silent socket
      # stall trips the read deadline within one missed-heartbeat window
      # rather than the previous 5-minute idle. See plan
      # `project/plans/sdk-hardening-and-verification.md` Layer 1.
      def initialize(sse_read_timeout: 90,
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

    # +on_error+: optional callable invoked on every SSE error edge. Parent
    # Quonfig::Client wires this to drive @sse_state -> :error so that
    # +connection_state+ reflects the disconnect (qfg-47c2.27). Without it
    # the SDK's public health primitive would lie about its own state during
    # a mid-run socket drop.
    def initialize(prefab_options, config_loader, options = nil, logger = nil, on_error: nil)
      @prefab_options = prefab_options
      @options = options || Options.new
      @config_loader = config_loader
      @connected = false
      @logger = logger || LOG
      @on_error = on_error
      @restart_total = 0
      @restart_mutex = Mutex.new
    end

    # qfg-ll6r: Layer 1 (SSE) restart counter — surfaces every disconnect edge
    # that ld-eventsource reports through on_error. The chaos harness pulls
    # this via Client#worker_restart_total(layer: '1') so kill-storm scenarios
    # (e.g. scenario 09 — proxy killed 5x in 30s) can assert restart_total >= 5
    # without depending on polled connection_state edges that may race past the
    # 50ms probe poller.
    def restart_total
      @restart_mutex.synchronize { @restart_total }
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

          next unless @client.closed?

          closed_count += @options.sleep_delay_for_new_connection_check

          next unless closed_count > @options.seconds_between_new_connection

          closed_count = 0
          @logger.debug 'Reconnecting SSE client'
          @client = connect(&load_configs)
        end
      end
    end

    def connect(&load_configs)
      url = "#{source}/api/v2/sse/config"
      cursor = current_cursor
      @logger.debug "SSE Streaming Connect to #{url} start_at #{cursor.inspect}"

      SSE::Client.new(url,
                      headers: headers,
                      read_timeout: @options.sse_read_timeout,
                      reconnect_time: @options.sse_default_reconnect_time,
                      last_event_id: cursor,
                      logger: Quonfig::InternalLogger.new(SSE::Client)) do |client|
        client.on_event do |event|
          if event.data.nil? || event.data.empty?
            @logger.error "SSE Streaming Error: Received empty data for url #{url}"
            client.close
            next
          end

          begin
            parsed = JSON.parse(event.data)
          rescue JSON::ParserError => e
            @logger.error "SSE Streaming Error: Failed to parse JSON for url #{url}: #{e.message}"
            client.close
            next
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

          # qfg-ll6r: bump Layer 1 restart_total on every error edge — chaos
          # scenario 09 (proxy killed 5x in 30s) asserts >= 5 restarts. Counted
          # here, not in the reconnect retry loop, because ld-eventsource
          # auto-reconnects most errors internally without ever flipping
          # `closed?` to true — and the error edge IS the disconnect, which is
          # what the supervisor contract counts.
          @restart_mutex.synchronize { @restart_total += 1 }

          # Notify the parent client BEFORE deciding whether to close — every
          # error edge is a disconnect signal as far as @sse_state goes, even
          # if we let the underlying SSE library handle reconnect itself.
          # qfg-47c2.27
          if @on_error
            begin
              @on_error.call(error)
            rescue StandardError => e
              @logger.error "SSE on_error callback raised: #{e.inspect}"
            end
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
      {
        'Authorization' => "Basic #{auth_string}",
        'Accept' => 'text/event-stream',
        'X-Quonfig-SDK-Version' => "ruby-#{Quonfig::VERSION}"
      }
    end

    def source
      @source_index = @source_index.nil? ? 0 : @source_index + 1

      @source_index = 0 if @source_index >= @prefab_options.sse_api_urls.size

      @prefab_options.sse_api_urls[@source_index]
    end

    # Compute a Last-Event-ID to resume the stream from. Three sources, in
    # priority order:
    #   1. config_loader.version  -- string ETag from last HTTP fetch (new path)
    #   2. config_loader.highwater_mark -- legacy numeric cursor
    #   3. nil -- no prior state; stream from HEAD
    def current_cursor
      if @config_loader.respond_to?(:version)
        v = @config_loader.version
        return v if v.is_a?(String) && !v.empty?
      end

      if @config_loader.respond_to?(:highwater_mark)
        hw = @config_loader.highwater_mark
        return hw.to_s if hw.is_a?(Numeric) && hw.positive?
        return hw if hw.is_a?(String) && !hw.empty?
      end

      nil
    end
  end
end
