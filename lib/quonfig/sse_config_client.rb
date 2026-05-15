# frozen_string_literal: true

require 'base64'
require 'json'
require 'net/http'
require 'uri'

module Quonfig
  # Event delivered to on_envelope. +id+ mirrors the SSE +id:+ field and is
  # consumed by callers that want the server cursor (tests + last-event-id
  # resume). +data+ is the raw +data:+ payload string. +envelope+ is the
  # parsed Quonfig::ConfigEnvelope.
  StreamEvent = Struct.new(:envelope, :id, :data)

  # SSE client for real-time config delivery from api-delivery-sse.
  #
  # Owns its reconnect loop end-to-end. sdk-go, sdk-python, and sdk-node all
  # reached the same conclusion: the wire format we consume (plain JSON
  # envelopes in single-line +data:+ frames, no named events, no retry
  # directives) is simple enough that an SDK-owned loop is clearer than a
  # library wrapper, and the operator-facing reconnect counter becomes
  # trivially correct because there is exactly one place that increments it
  # (qfg-35sm; replaces the ld-eventsource integration from qfg-ie49 +
  # qfg-cf52, which required log-line scraping and a raise-proof logger
  # wrapper to observe reconnects through the upstream library).
  class SSEConfigClient
    class Options
      attr_reader :sse_read_timeout, :sse_connect_timeout,
                  :sse_initial_reconnect_delay, :sse_max_reconnect_delay

      # sse_read_timeout: 90s = 3x the 30s server heartbeat. A silent socket
      # stall trips within one missed-heartbeat window rather than the OS
      # TCP idle (often hours).
      #
      # sse_initial_reconnect_delay / sse_max_reconnect_delay: backoff bounds.
      # Each failed reconnect doubles the delay (with +/-50% jitter) up to the
      # max. A successful event delivery resets the delay to the initial
      # value — matches sdk-python's policy. A clean server-initiated FIN is
      # treated as "not a failure for backoff purposes" because LBs recycling
      # connections is normal; the reconnect counter still increments.
      def initialize(sse_read_timeout: 90,
                     sse_connect_timeout: 10,
                     sse_initial_reconnect_delay: 1.0,
                     sse_max_reconnect_delay: 30.0)
        @sse_read_timeout = sse_read_timeout
        @sse_connect_timeout = sse_connect_timeout
        @sse_initial_reconnect_delay = sse_initial_reconnect_delay.to_f
        @sse_max_reconnect_delay = sse_max_reconnect_delay.to_f
      end
    end

    LOG = Quonfig::InternalLogger.new(self)

    # +on_error+: optional callable invoked on every SSE error edge. Parent
    # Quonfig::Client wires this to drive @sse_state -> :error so that
    # +connection_state+ reflects the disconnect (qfg-47c2.27).
    def initialize(prefab_options, config_loader, options = nil, logger = nil, on_error: nil)
      @prefab_options = prefab_options
      @options = options || Options.new
      @config_loader = config_loader
      @logger = logger || LOG
      @on_error = on_error

      @stopped = Concurrent::AtomicBoolean.new(false)
      @restart_total = 0
      @restart_mutex = Mutex.new

      @on_envelope_error_total = 0
      @on_envelope_error_mutex = Mutex.new

      @conn_mutex = Mutex.new
      @active_http = nil

      @source_index = -1
      @last_event_id = nil
    end

    # Layer 1 (SSE) reconnect counter. Bumped exactly once per reconnect
    # attempt — never per error edge, never per envelope. Read by
    # Quonfig::Client#worker_restart_total(layer: '1') and asserted by chaos
    # scenario 09 (>= 5 after 5 proxy flaps in 30s).
    def restart_total
      @restart_mutex.synchronize { @restart_total }
    end

    # qfg-m3lk: count of user-supplied on_envelope callback invocations that
    # raised. Surfaced for operator visibility — a non-zero value here with
    # restart_total stable means a caller-side listener bug, not a transport
    # problem. (Pre-fix, those raises propagated into run_loop's rescue and
    # masqueraded as transport errors, causing reconnect storms.)
    def on_envelope_error_total
      @on_envelope_error_mutex.synchronize { @on_envelope_error_total }
    end

    def start(&on_envelope)
      return if @prefab_options.sse_api_urls.nil? || @prefab_options.sse_api_urls.empty?

      @worker = Thread.new { run_loop(&on_envelope) }
    end

    # Shut down. Interrupts the in-flight stream by closing the underlying
    # socket from this thread — the worker thread observes the resulting
    # IOError, sees @stopped == true, and exits cleanly.
    def close
      @stopped.make_true
      @conn_mutex.synchronize do
        begin
          @active_http&.finish
        rescue StandardError
          # already closed / never started — idempotent
        end
        @active_http = nil
      end
      @worker&.join(2)
      @worker = nil
    end

    # Public so tests can assert the headers shape. Body of the request is
    # always empty; this is the full set api-delivery-sse sees.
    def headers
      auth = "1:#{@prefab_options.sdk_key}"
      auth_string = Base64.strict_encode64(auth)
      h = {
        'Authorization' => "Basic #{auth_string}",
        'Accept' => 'text/event-stream',
        'Cache-Control' => 'no-cache',
        'X-Quonfig-SDK-Version' => "ruby-#{Quonfig::VERSION}"
      }
      cursor = current_cursor
      h['Last-Event-Id'] = cursor if cursor
      h
    end

    # Compute a Last-Event-ID for the next request. Three sources, in
    # priority order:
    #   1. @last_event_id  -- set by the most recent event we processed
    #   2. config_loader.version  -- string ETag from last HTTP fetch
    #   3. config_loader.highwater_mark  -- legacy numeric cursor
    # Returns nil if no prior state exists.
    def current_cursor
      return @last_event_id if @last_event_id && !@last_event_id.empty?

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

    private

    # Long-lived reconnect loop. One iteration = one connect attempt. Bumps
    # restart_total *before* every retry — so the counter answers "how many
    # times have we reconnected after a drop" rather than "how many connect
    # attempts have occurred." The first attempt is not a restart.
    #
    # qfg-tj18: the body is wrapped in
    # +Thread.handle_interrupt(SSEReadDeadlineExceeded => :on_blocking)+ so a
    # watchdog raise that's already been queued (the watchdog's mutex covers
    # the *decision* to fire but cannot un-queue a delivered raise) lands
    # only at a blocking-IO checkpoint. Inside stream_once we explicitly
    # re-enable +:immediate+ around the +read_body+ block where we *do*
    # want the raise to wake the read. A per-iteration paranoid rescue
    # catches any late-landing raise that escapes the inner +rescue
    # StandardError+ (e.g. lands inside +interruptible_sleep+ between
    # iterations) so the worker thread never silently dies.
    def run_loop(&on_envelope)
      Thread.handle_interrupt(SSEReadDeadlineExceeded => :on_blocking) do
        delay = @options.sse_initial_reconnect_delay
        first_attempt = true

        until @stopped.value
          begin
            unless first_attempt
              increment_restart!
              interruptible_sleep(jittered(delay))
              break if @stopped.value
            end
            first_attempt = false

            connected_at_least_once = false
            begin
              stream_once do |event|
                connected_at_least_once = true
                # Persist the most recent id so the next reconnect resumes
                # from there via Last-Event-Id. Updated *before* the user
                # callback runs so a raising listener still advances the
                # cursor — the event was delivered to us, the bug is on the
                # caller side.
                @last_event_id = event.id if event.id
                # qfg-m3lk: callback exceptions are isolated. A buggy
                # listener must not look like a transport error and trigger
                # a reconnect.
                invoke_on_envelope_safely(on_envelope, event)
                # A connection healthy enough to deliver a real envelope
                # earns a reset of the backoff. Sustained outages never
                # reach this branch (no event ever delivered) so the
                # exponential growth still holds.
                delay = @options.sse_initial_reconnect_delay
              end
            rescue StandardError => e
              handle_error(e) unless @stopped.value
            end

            # Backoff only grows on failed connect attempts. A server-
            # initiated clean FIN after a healthy session (normal LB
            # recycling) reuses the same delay — punishing it would make
            # us look broken under benign rolling restarts. Matches
            # sdk-go's `connectedOK` distinction.
            delay = [delay * 2, @options.sse_max_reconnect_delay].min unless connected_at_least_once
          rescue SSEReadDeadlineExceeded => e
            # Paranoid backstop (qfg-tj18). A watchdog raise that landed
            # outside +stream_once+ — typically in +interruptible_sleep+
            # — must not kill the worker thread. We log loudly and let the
            # +until+ loop carry on.
            @logger.error "SSE watchdog late-raise contained: #{e.inspect}; resuming loop"
          end
        end
      end
    ensure
      register_active(nil)
    end

    # Opens one SSE request and yields each parsed event until the stream
    # ends (clean FIN, error, or stop). Raises on transport errors so the
    # caller can apply backoff. Clean FIN returns without raising.
    #
    # A watchdog thread closes the socket if no bytes arrive within
    # +sse_read_timeout+. Net::HTTP#read_timeout is NOT reliable for the
    # streaming +read_body do |chunk|+ form — the underlying BufferedIO
    # reads bypass it in practice (a silent server stall blocks indefinitely
    # against a configured deadline). sdk-go and sdk-node hit the same
    # gotcha and solve it the same way: per-chunk reset, async close on
    # expiry (chaos scenario 02 — sse_silent_stall).
    def stream_once(&block)
      url = "#{current_url}/api/v2/sse/config"
      cursor = current_cursor
      @logger.debug "SSE Streaming Connect to #{url} start_at #{cursor.inspect}"

      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = @options.sse_connect_timeout
      # Keep Net::HTTP's read_timeout as a backstop for the header read
      # (where it does apply reliably). The watchdog covers the body path.
      http.read_timeout = @options.sse_read_timeout

      req = Net::HTTP::Get.new(uri.request_uri, headers)

      http.start
      register_active(http)

      watchdog = ReadDeadlineWatchdog.new(
        worker: Thread.current, deadline_s: @options.sse_read_timeout,
        stopped: @stopped, logger: @logger
      )
      watchdog.start

      begin
        http.request(req) do |resp|
          code = resp.code.to_i
          if code != 200
            err = SSEHTTPStatusError.new(code)
            @logger.error "SSE Streaming Error: HTTP #{code} for url #{url}"
            invoke_on_error(err)
            raise err
          end

          parser = EventParser.new
          # qfg-tj18: run_loop wraps the body in +:on_blocking+ which
          # *would* still deliver during read_body (read_body is a
          # blocking IO call), but be explicit: we want the watchdog raise
          # to land here without ambiguity.
          Thread.handle_interrupt(SSEReadDeadlineExceeded => :immediate) do
            resp.read_body do |chunk|
              watchdog.reset!
              break if @stopped.value

              parser.feed(chunk, &block)
            end
          end
          # read_body returned cleanly — either a server-initiated FIN, or
          # the watchdog closed the socket on a silent stall. Either way,
          # the outer loop will reconnect and bump restart_total on the
          # next iteration.
          @logger.debug "SSE stream ended for url #{url}"
        end
      ensure
        watchdog.stop
        register_active(nil)
        begin
          http.finish if http.started?
        rescue StandardError
          # already closed
        end
      end
    end

    # Track the active connection so close() can interrupt a blocked
    # read_body from another thread. Guarded by @conn_mutex.
    def register_active(http)
      @conn_mutex.synchronize { @active_http = http }
    end

    def increment_restart!
      @restart_mutex.synchronize { @restart_total += 1 }
    end

    def handle_error(error)
      @logger.error "SSE Streaming Error: #{error.inspect}"
      invoke_on_error(error)
    end

    # qfg-m3lk: rescue StandardError (NOT Exception) so SystemExit /
    # Interrupt / SignalException still escape — Ctrl-C inside a customer
    # callback must still kill the process. StandardError is the right
    # boundary for "the caller's listener has a bug".
    def invoke_on_envelope_safely(on_envelope, event)
      on_envelope.call(event.envelope, event, :sse)
    rescue StandardError => e
      @on_envelope_error_mutex.synchronize { @on_envelope_error_total += 1 }
      bt = (e.backtrace || []).first(5).join("\n  ")
      @logger.error "SSE on_envelope callback raised: #{e.class}: #{e.message}\n  #{bt}"
    end

    def invoke_on_error(error)
      return unless @on_error

      begin
        @on_error.call(error)
      rescue StandardError => e
        @logger.error "SSE on_error callback raised: #{e.inspect}"
      end
    end

    # +/-50% jitter — caps thundering-herd amplitude after a partition heal.
    # Identical shape to ld-eventsource's Backoff#next_interval (and
    # sdk-go's runLoop jitter) so we don't surprise operators familiar with
    # those.
    def jittered(delay)
      (delay / 2) + rand(delay / 2.0)
    end

    # Sleep with interrupt: chunks the sleep so close() during a long
    # backoff doesn't block shutdown for tens of seconds.
    def interruptible_sleep(seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      until @stopped.value
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if remaining <= 0

        sleep([remaining, 0.1].min)
      end
    end

    # Rotate through configured SSE URLs. The same rotation rule the
    # previous implementation used, preserved so multi-region failover
    # behavior is unchanged.
    def current_url
      urls = @prefab_options.sse_api_urls
      @source_index = (@source_index + 1) % urls.size
      urls[@source_index]
    end

    # Internal: HTTP-status sentinel error for non-200 SSE responses. Surfaces
    # the status code through #message so parent on_error callbacks can log
    # meaningfully without depending on ld-eventsource's error hierarchy.
    class SSEHTTPStatusError < StandardError
      attr_reader :status_code

      def initialize(status_code)
        @status_code = status_code
        super("HTTP #{status_code}")
      end
    end

    # Raised by the watchdog into the worker thread when the per-chunk
    # read deadline elapses. Caught by run_loop's rescue, indistinguishable
    # from any other transport error for backoff/restart purposes.
    class SSEReadDeadlineExceeded < StandardError; end

    # Background watchdog that interrupts the worker thread if no chunk
    # arrives within +deadline_s+ seconds. Uses Thread#raise — the only
    # reliable cross-platform way to unblock a Ruby thread blocked in
    # +Net::HTTP+'s body-read on macOS. (Closing or shutting down the
    # underlying socket from another thread does NOT wake the reader on
    # macOS; the kernel discards future reads but the in-flight syscall
    # stays blocked until something else trips. sdk-go and sdk-node solve
    # the equivalent problem with context cancellation / AbortController,
    # which Ruby lacks at the IO layer.) Thread#raise is essentially what
    # +Timeout.timeout+ does internally; using it directly avoids
    # Timeout.timeout's sketch reputation around ensure blocks.
    class ReadDeadlineWatchdog
      POLL_INTERVAL = 0.25

      def initialize(worker:, deadline_s:, stopped:, logger:)
        @worker = worker
        @deadline_s = deadline_s
        @stopped = stopped
        @logger = logger
        @active = true
        # Mutex covers @active AND the decision to fire Thread#raise. stop()
        # holds the mutex when flipping @active false, so a +stop+ that
        # arrives mid-deadline-check cannot lose the race against the
        # watchdog's @worker.raise call (which would inject a spurious
        # SSEReadDeadlineExceeded into the worker thread right after a
        # clean read_body return).
        @mutex = Mutex.new
        @last_read_at = Concurrent::AtomicReference.new(Process.clock_gettime(Process::CLOCK_MONOTONIC))
      end

      def start
        @thread = Thread.new { watch }
      end

      def reset!
        @last_read_at.set(Process.clock_gettime(Process::CLOCK_MONOTONIC))
      end

      def stop
        @mutex.synchronize { @active = false }
        @thread&.join(1)
        @thread = nil
      end

      private

      def watch
        loop do
          sleep POLL_INTERVAL
          break unless @mutex.synchronize { @active } && !@stopped.value

          idle = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_read_at.value
          next if idle < @deadline_s

          fired = @mutex.synchronize do
            next false unless @active && !@stopped.value

            @logger.debug "SSE read deadline exceeded (#{idle.round(1)}s idle >= #{@deadline_s}s); interrupting worker"
            @worker.raise(SSEReadDeadlineExceeded.new("SSE read deadline #{@deadline_s}s exceeded"))
            true
          end
          break if fired
        end
      rescue StandardError => e
        # Watchdog must never crash the SDK. Worst case we silently fall
        # back to Net::HTTP's own (unreliable) read_timeout.
        @logger.debug "SSE watchdog error: #{e.inspect}"
      end
    end

    # Streaming SSE parser. Accepts byte chunks (any encoding), yields one
    # Quonfig::StreamEvent per complete event. Tolerates:
    #   - chunks that split a UTF-8 multi-byte character (buffer in 8-bit,
    #     transcode whole lines)
    #   - chunks that split a line mid-way
    #   - any of CR / LF / CRLF as line terminators
    #   - +data:+, +data: + (optional space per SSE spec)
    #   - +:comment+ lines (keepalives — ignored)
    #   - multi-line +data:+ (concatenated with +\n+, per spec)
    # Ignores +event:+ and +retry:+ — api-delivery does not emit them and the
    # Quonfig wire contract does not honor reconnect-time directives.
    # Malformed +data:+ JSON is logged and skipped; one bad event does not
    # tear down the stream.
    class EventParser
      def initialize(logger: nil)
        @logger = logger
        @reader = LineReader.new
        @data = +''
        @have_data = false
        @id = nil
      end

      def feed(chunk)
        @reader.feed(chunk) do |line|
          if line.empty?
            event = flush
            yield event if event
          elsif line.start_with?(':')
            # comment / keepalive — ignore
          else
            process_field(line)
          end
        end
      end

      private

      def process_field(line)
        idx = line.index(':')
        return unless idx

        name = line[0...idx]
        rest = line[(idx + 1)..]
        rest = rest[1..] if rest.start_with?(' ')

        case name
        when 'data'
          if @have_data
            @data << "\n" << rest
          else
            @data = rest
            @have_data = true
          end
        when 'id'
          @id = rest unless rest.include?("\x00")
          # event: / retry: are intentionally ignored
        end
      end

      def flush
        return nil unless @have_data

        data = @data
        id = @id
        @data = +''
        @have_data = false
        # NB: @id persists across events — the SSE spec says last-event-id
        # is sticky until overwritten. Matches ld-eventsource.

        begin
          parsed = JSON.parse(data)
        rescue JSON::ParserError => e
          (@logger || LOG).error "SSE Streaming Error: malformed JSON: #{e.message}"
          return nil
        end

        envelope = Quonfig::ConfigEnvelope.new(
          configs: parsed['configs'] || [],
          meta: parsed['meta'] || {}
        )
        StreamEvent.new(envelope, id, data)
      end
    end

    # Byte-level line reader. Accepts arbitrary chunks, yields one UTF-8
    # line per call to the block. Terminator-stripped (CR / LF / CRLF
    # supported). Modeled on ld-eventsource's BufferedLineReader — same
    # invariants: split bytes-not-chars while scanning, force-encode to
    # UTF-8 only once a complete line is sliced out, so a multi-byte
    # character spanning two chunks does not raise Encoding::CompatibilityError.
    class LineReader
      def initialize
        @buffer = +''.b
        @last_was_cr = false
      end

      def feed(chunk)
        @buffer << chunk.b
        loop do
          idx = @buffer.index(/[\r\n]/)
          break if idx.nil?

          ch = @buffer[idx]
          if idx.zero? && ch == "\n" && @last_was_cr
            # Dangling LF of a CRLF pair split across chunks — consume and skip.
            @last_was_cr = false
            @buffer.slice!(0, 1)
            next
          end

          line = @buffer[0, idx].force_encoding('UTF-8')
          consume = idx + 1
          @last_was_cr = false
          if ch == "\r"
            if consume == @buffer.bytesize
              # CR at end of buffer — could be CRLF split across feeds.
              @last_was_cr = true
            elsif @buffer[consume] == "\n"
              consume += 1
            end
          end
          @buffer.slice!(0, consume)
          yield line
        end
      end
    end
  end
end
