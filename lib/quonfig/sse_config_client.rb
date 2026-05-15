# frozen_string_literal: true

require 'base64'
require 'json'

module Quonfig
  class SSEConfigClient
    # ld-eventsource auto-reconnects on a clean socket EOF (server FIN)
    # *internally* — it never calls +on_error+ for that case, only for
    # ECONNREFUSED-style failures (qfg-ie49; see chaos scenario 09). The one
    # signal it emits for any reconnect is an info-level
    # "Will retry connection after ..." line, logged once per reconnect attempt
    # and never on the first connect. Wrapping the logger we hand to
    # SSE::Client lets the SDK observe those internal reconnects without
    # touching the data path. This is the only reconnect hook ld-eventsource
    # >= 2.0 exposes.
    class ReconnectCountingLogger
      RECONNECT_SIGNAL = 'Will retry connection after'

      LEVELS = %i[trace debug info warn error fatal].freeze

      def initialize(wrapped, &on_reconnect)
        @wrapped = wrapped
        @on_reconnect = on_reconnect
      end

      # Crash-safe by construction: ld-eventsource calls this logger from
      # inside its bare-Thread +run_stream+ loop, and several of those call
      # sites (+connect+, +log_and_dispatch_error+, query-param building) are
      # NOT wrapped in a rescue. Any exception that escapes a logger call kills
      # the worker thread with +@stopped+ still false, so +closed?+ never flips
      # true and the SDK's @retry_thread never reconnects — the SSE stream is
      # silently wedged forever (qfg-cf52, the chaos scenario 05 flake). Every
      # step here is therefore independently guarded: a throwing message block,
      # a throwing on_reconnect callback, or a throwing wrapped logger can
      # never propagate out of this method.
      LEVELS.each do |level|
        define_method(level) do |message = nil, &block|
          begin
            message = block.call if message.nil? && block
          rescue StandardError
            message = nil
          end

          if level == :info && message.to_s.include?(RECONNECT_SIGNAL)
            begin
              @on_reconnect.call
            rescue StandardError
              nil
            end
          end

          begin
            @wrapped.public_send(level, message) if @wrapped.respond_to?(level)
          rescue StandardError
            nil
          end
        end
      end

      def level
        @wrapped&.level
      end

      def level=(new_level)
        @wrapped.level = new_level if @wrapped.respond_to?(:level=)
      end
    end

    class Options
      attr_reader :sse_read_timeout, :seconds_between_new_connection,
                  :sse_default_reconnect_time, :sleep_delay_for_new_connection_check,
                  :errors_to_close_connection, :sse_reconnect_reset_interval

      # sse_read_timeout: 90s = 3x the 30s server heartbeat. A silent socket
      # stall trips the read deadline within one missed-heartbeat window
      # rather than the previous 5-minute idle. See plan
      # `project/plans/sdk-hardening-and-verification.md` Layer 1.
      #
      # sse_reconnect_reset_interval: 1s (ld-eventsource default is 60s). The
      # ld-eventsource backoff only resets to the base interval once a
      # connection has stayed up this long; until then each reconnect doubles
      # the delay (1s, 2s, 4s, 8s...). With the 60s default, a flapping
      # connection (chaos scenario 09 — proxy killed every 6s) backs off so
      # fast the SDK is mid-sleep when the next kill lands and never observes
      # it. Resetting after 1s of healthy connection mirrors sdk-python, which
      # resets its backoff on every successful connect (sdk-python/quonfig/
      # sse.py). A *sustained* outage still backs off exponentially: no
      # connection succeeds, so `mark_success` is never called and the reset
      # never triggers (qfg-ie49).
      def initialize(sse_read_timeout: 90,
                     seconds_between_new_connection: 5,
                     sleep_delay_for_new_connection_check: 1,
                     sse_default_reconnect_time: SSE::Client::DEFAULT_RECONNECT_TIME,
                     sse_reconnect_reset_interval: 1,
                     errors_to_close_connection: [HTTP::ConnectionError])
        @sse_read_timeout = sse_read_timeout
        @seconds_between_new_connection = seconds_between_new_connection
        @sse_default_reconnect_time = sse_default_reconnect_time
        @sse_reconnect_reset_interval = sse_reconnect_reset_interval
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

    # qfg-ll6r / qfg-ie49: Layer 1 (SSE) restart counter — counts every
    # *reconnect*, from two sources:
    #   1. ld-eventsource's own internal reconnect (clean FIN, read timeout,
    #      transient errors it doesn't surface) — observed via the
    #      ReconnectCountingLogger "Will retry connection after" signal.
    #   2. SDK-driven reconnects in @retry_thread, after a closing error
    #      (HTTP::ConnectionError) made us close the SSE::Client outright.
    # These two are mutually exclusive per disconnect, so there is no
    # double-count. on_error is deliberately NOT a source — ld-eventsource
    # reconnects internally after most non-closing errors, so counting the
    # error edge AND the reconnect would double up (qfg-ie49).
    #
    # The chaos harness pulls this via Client#worker_restart_total(layer: '1')
    # so kill-storm scenarios (e.g. scenario 09 — proxy killed 5x in 30s) can
    # assert restart_total >= 5 even when the kills produce clean FINs that
    # never reach on_error.
    def restart_total
      @restart_mutex.synchronize { @restart_total }
    end

    # Bump the Layer 1 reconnect counter. Called from the ld-eventsource
    # worker thread (via ReconnectCountingLogger) and from @retry_thread.
    def count_restart!
      @restart_mutex.synchronize { @restart_total += 1 }
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
          # SDK-driven reconnect: a closing error (HTTP::ConnectionError)
          # closed the previous SSE::Client, so ld-eventsource's own
          # reconnect loop has exited and won't emit the "Will retry" signal.
          # Count it here instead (qfg-ie49).
          count_restart!
          @client = connect(&load_configs)
        end
      end
    end

    def connect(&load_configs)
      url = "#{source}/api/v2/sse/config"
      cursor = current_cursor
      @logger.debug "SSE Streaming Connect to #{url} start_at #{cursor.inspect}"

      # Wrap the ld-eventsource logger so internal reconnects (clean FIN,
      # read-timeout, transient errors) bump restart_total — they never reach
      # on_error (qfg-ie49).
      sse_logger = ReconnectCountingLogger.new(
        Quonfig::InternalLogger.new(SSE::Client)
      ) { count_restart! }

      SSE::Client.new(url,
                      headers: headers,
                      read_timeout: @options.sse_read_timeout,
                      reconnect_time: @options.sse_default_reconnect_time,
                      reconnect_reset_interval: @options.sse_reconnect_reset_interval,
                      last_event_id: cursor,
                      logger: sse_logger) do |client|
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

          # qfg-ie49: restart_total is NOT bumped here. ld-eventsource
          # auto-reconnects after most non-closing errors, and that reconnect
          # is already counted via ReconnectCountingLogger; bumping here too
          # would double-count. For closing errors (HTTP::ConnectionError) the
          # reconnect is counted in @retry_thread instead. on_error's job is
          # purely to notify the parent client of the disconnect edge.

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
