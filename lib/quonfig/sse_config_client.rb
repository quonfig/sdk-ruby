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
      # max. A connection that delivers its first valid frame (a config
      # envelope or a keepalive) resets the delay to the initial value. A
      # clean server-initiated FIN after such a frame is "not a failure for
      # backoff purposes" because LBs recycling connections is normal; the
      # reconnect counter still increments. A connection that ends before any
      # frame is a failed attempt (qfg-goi1.10.43).
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

    # Auth-class statuses (rule R1, qfg-goi1.10.26). On the stream they keep the
    # normal reconnect ladder: SSE alone never stops retrying and never enters
    # auth-failed (R2); the client's fallback poller decides that from a whole
    # fetch cycle. They only get their own log line: WARN once per status,
    # re-armed by a 200, DEBUG otherwise (R5).
    AUTH_HTTP_CODES = [401, 403, 404, 410].freeze

    # @deprecated since 1.8.0. qfg-i5xv's "terminal" codes. Nothing is terminal
    # any more (the latch is gone, qfg-goi1.10.26); kept as an alias of
    # AUTH_HTTP_CODES for code that references the constant.
    TERMINAL_HTTP_CODES = AUTH_HTTP_CODES

    # qfg-6y44: headroom added to +sse_read_timeout+ when configuring
    # Net::HTTP#read_timeout. The ReadDeadlineWatchdog already covers both the
    # header and body reads at exactly +sse_read_timeout+; Net's own
    # read_timeout is only a redundant backstop. Arming it at the *same* value
    # as the watchdog makes the two race — and on the body path Net's
    # (unreliable) timeout can fire first, surfacing a Net::ReadTimeout instead
    # of the SSEReadDeadlineExceeded the SDK is instrumented around. Giving
    # Net's read_timeout this much headroom keeps it a backstop without ever
    # letting it win the race.
    READ_TIMEOUT_HEADROOM = 30

    # Size-caps rule (qfg-6vno.8, supervisor-test-contract.md "Rule — size
    # caps"; sdk-go's sseMaxLine): one SSE event, any single line and the sum
    # of a multi-line data:, is capped at 4 MiB. The parser stops reading at
    # the cap, so memory per stream stays near the cap plus one read chunk
    # even for an event with no terminator. Over the cap is not a frame: the
    # connection is a failed attempt. A constant, not an option.
    MAX_EVENT_BYTES = 4 * 1024 * 1024

    # +on_error+: optional callable invoked on every SSE error edge. Parent
    # Quonfig::Client wires this to drive @sse_state -> :error so that
    # +connection_state+ reflects the disconnect (qfg-47c2.27). A connection
    # that ends before its first valid frame, clean EOF included, is an error
    # edge too (qfg-goi1.10.43).
    #
    # +on_connected+: optional callable invoked once per connection, at its
    # first valid frame (a keepalive, or a data block that validates as a
    # config envelope), before that frame's envelope reaches +on_envelope+.
    # Never on the 200 headers alone (supervisor-test-contract.md "Rule — a
    # connection is `connected` at its first valid frame").
    def initialize(prefab_options, config_loader, options = nil, logger = nil, on_error: nil, on_connected: nil)
      @prefab_options = prefab_options
      @options = options || Options.new
      @config_loader = config_loader
      @logger = logger || LOG
      @on_error = on_error
      @on_connected = on_connected

      @stopped = Concurrent::AtomicBoolean.new(false)
      @restart_total = 0
      @restart_mutex = Mutex.new

      @on_envelope_error_total = 0
      @on_envelope_error_mutex = Mutex.new

      @conn_mutex = Mutex.new
      @active_http = nil

      @last_event_id = nil
      # Auth-class statuses already logged at WARN since the last 200 (R5).
      @auth_warned = Set.new
      # qfg-7h5d.1.9 / qfg-41nh.6: latches true if a connection attempt ever
      # targets a non-primary sse_api_urls leg. The failover epic asserts SSE
      # does NOT fail over to the secondary (f05) — the stream is PINNED to
      # sse_api_urls[0] and degrades via the single-upstream SSE↔HTTP fallback,
      # so with a correct #current_url this never flips even when a secondary
      # stream URL is configured (options derive one from api_urls by default).
      # The latch is measured at the dial site in #stream_once, so a regression
      # that reintroduces stream-URL rotation is observable to the failover
      # chaos probe (f05) and to operators.
      @failed_over_to_secondary = false
      # Oversized gate (size caps, sdk-go's +oversized+): set when a stream
      # ended on an event over MAX_EVENT_BYTES. While set, a keepalive is not
      # a frame, so a connection that only re-delivers the oversized snapshot
      # never reports connected and the fallback poller keeps config fresh.
      # The first INSTALLED envelope clears it (and ends the WARN episode):
      # the on_envelope block returns :updated for an install, and an
      # envelope the reject-older guard drops neither clears the gate nor
      # counts as a frame (qfg-6vno.20.8). Touched only by the worker thread.
      @oversized = false
    end

    # True if the live SSE stream has ever connected to a non-primary leg. Read
    # by the failover chaos probe (f05). See @failed_over_to_secondary.
    def failed_over_to_secondary?
      @failed_over_to_secondary
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

    # True while the worker thread that owns the stream (and its reconnect
    # loop) is running. Stays true across a reconnect — the worker owns the
    # retry, so a blip is not "no channel". Used by Client#connection_state
    # so that diagnostic derives from liveness rather than a stored flag
    # (qfg-lv4n.1).
    def alive?
      @worker&.alive? || false
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
              interruptible_sleep(jittered(Quonfig::Waits.duration(:sse, delay)))
              break if @stopped.value
            end
            first_attempt = false

            # First-frame rule (qfg-goi1.10.43): this connection counts as
            # connected only at its first valid frame. Raised once, from the
            # parser, before the frame's envelope is installed.
            #
            # While the oversized gate is set the parser reports only
            # envelopes as frames, and even those are deferred until the
            # on_envelope block says the envelope installed (:updated): an
            # envelope the reject-older guard drops is not an install, so it
            # neither ends the episode nor makes the connection connected.
            frame_seen = false
            mark_frame = lambda do
              next if frame_seen

              frame_seen = true
              invoke_on_connected
            end
            on_frame = lambda do
              mark_frame.call unless @oversized
            end
            begin
              ended_url = stream_once(on_frame) do |event|
                # Persist the most recent id so the next reconnect resumes
                # from there via Last-Event-Id. Updated *before* the user
                # callback runs so a raising listener still advances the
                # cursor — the event was delivered to us, the bug is on the
                # caller side.
                @last_event_id = event.id if event.id
                # qfg-m3lk: callback exceptions are isolated. A buggy
                # listener must not look like a transport error and trigger
                # a reconnect.
                result = invoke_on_envelope_safely(on_envelope, event)
                if @oversized && result == :updated
                  @oversized = false
                  mark_frame.call
                end
              end
              # A clean EOF before any frame (200 headers then close) is a
              # failed attempt, exactly like a connect error: report it so
              # the client leaves :connected and arms the fallback poller.
              # This is what bounds ruby's transparent reconnect: connected
              # survives a clean-EOF reconnect only until the next connection
              # ends frameless.
              handle_frameless_end(ended_url) unless frame_seen || @stopped.value
            rescue SSEEventTooLargeError => e
              # A failed attempt even if an earlier frame arrived on this
              # connection (sdk-go returns frameSeen=false here).
              frame_seen = false
              handle_oversized_event(e) unless @stopped.value
            rescue StandardError => e
              handle_error(e) unless @stopped.value
            end

            # The backoff resets only for a connection that delivered a
            # frame; it then reconnects at the initial delay even after a
            # clean FIN (normal LB recycling) or an IO error later in the
            # session. Every other attempt (connect error, non-200, or a
            # frameless 200) doubles it. Sustained outages never deliver a
            # frame, so the exponential growth still holds. Matches sdk-go's
            # connectOnce "frame seen" result.
            delay = if frame_seen
                      @options.sse_initial_reconnect_delay
                    else
                      [delay * 2, @options.sse_max_reconnect_delay].min
                    end
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
    # caller can apply backoff. Clean FIN returns the URL without raising.
    # +on_frame+ is called at every valid frame (see EventParser#feed).
    #
    # A watchdog thread closes the socket if no bytes arrive within
    # +sse_read_timeout+. Net::HTTP#read_timeout is NOT reliable for the
    # streaming +read_body do |chunk|+ form — the underlying BufferedIO
    # reads bypass it in practice (a silent server stall blocks indefinitely
    # against a configured deadline). sdk-go and sdk-node hit the same
    # gotcha and solve it the same way: per-chunk reset, async close on
    # expiry (chaos scenario 02 — sse_silent_stall).
    def stream_once(on_frame = nil, &block)
      base = current_url
      # f05 latch: record if this connection attempt targets a non-primary
      # stream leg. With the pin in #current_url this is structurally false;
      # measuring at the dial site (rather than inside URL selection) keeps a
      # rotation regression observable to the chaos probe.
      @failed_over_to_secondary = true if base != @prefab_options.sse_api_urls.first
      url = "#{base}/api/v2/sse/config"
      cursor = current_cursor
      @logger.debug "SSE Streaming Connect to #{url} start_at #{cursor.inspect}"

      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = @options.sse_connect_timeout
      # Keep Net::HTTP's read_timeout as a backstop for the header read
      # (where it does apply reliably). The watchdog covers the body path —
      # so read_timeout gets READ_TIMEOUT_HEADROOM over the watchdog deadline
      # to guarantee the watchdog fires first and we get a deterministic
      # SSEReadDeadlineExceeded rather than a racy Net::ReadTimeout (qfg-6y44).
      http.read_timeout = @options.sse_read_timeout + READ_TIMEOUT_HEADROOM

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
          check_response_status!(resp.code.to_i, url)

          parser = EventParser.new(keepalive_is_frame: !@oversized)
          # qfg-tj18: run_loop wraps the body in +:on_blocking+ which
          # *would* still deliver during read_body (read_body is a
          # blocking IO call), but be explicit: we want the watchdog raise
          # to land here without ambiguity.
          Thread.handle_interrupt(SSEReadDeadlineExceeded => :immediate) do
            resp.read_body do |chunk|
              watchdog.reset!
              # Never +break+ here (qfg-yrly): a break returns into
              # Net::HTTPResponse#reading_body, which then calls +body+ to
              # drain the rest of the response with no block. On an endless
              # SSE stream that blocks the worker forever. Raising skips the
              # drain, and Net::HTTP closes the socket on the way out.
              raise SSEStopRequested if @stopped.value

              parser.feed(chunk, on_frame: on_frame, &block)
            end
          end
          # read_body returned cleanly — either a server-initiated FIN, or
          # the watchdog closed the socket on a silent stall. Either way,
          # the outer loop will reconnect and bump restart_total on the
          # next iteration.
          @logger.debug "SSE stream ended for url #{url}"
        end
        url
      rescue SSEStopRequested
        url
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

    # Classify the stream response. Raises for any non-200 so run_loop applies
    # its backoff.
    #
    # Auth class (401/403/404/410, qfg-goi1.10.26): no latch. The normal
    # ladder applies and run_loop's handle_error fires on_error once, so the
    # client schedules the fallback poller exactly as for any drop; that
    # poller's fetch cycle is what decides auth-failed (R2). Logged WARN once
    # per status until a 200 re-arms it, DEBUG otherwise (R5), so a revoked
    # key does not log two ERRORs per attempt for the ~2 min before entry.
    def check_response_status!(code, url)
      if AUTH_HTTP_CODES.include?(code)
        if @auth_warned.add?(code)
          @logger.warn "SSE Streaming Error: HTTP #{code} for url #{url}; " \
                       'the SDK key may be invalid or revoked (check the SDK key); retrying'
        else
          @logger.debug "SSE Streaming Error: HTTP #{code} for url #{url}; retrying"
        end
        raise SSEHTTPAuthError, code
      end
      if code != 200
        err = SSEHTTPStatusError.new(code)
        @logger.error "SSE Streaming Error: HTTP #{code} for url #{url}"
        invoke_on_error(err)
        raise err
      end

      @auth_warned.clear
    end

    # Track the active connection so close() can interrupt a blocked
    # read_body from another thread. Guarded by @conn_mutex.
    def register_active(http)
      @conn_mutex.synchronize { @active_http = http }
    end

    def increment_restart!
      @restart_mutex.synchronize { @restart_total += 1 }
    end

    # A connection that returned 200 and ended cleanly before its first valid
    # frame (qfg-goi1.10.43).
    def handle_frameless_end(url)
      err = SSEFramelessSessionError.new
      @logger.warn "SSE Streaming Error: stream for url #{url} ended before its first frame; " \
                   'treating it as a failed attempt'
      invoke_on_error(err)
    end

    def invoke_on_connected
      return unless @on_connected

      begin
        @on_connected.call
      rescue StandardError => e
        @logger.error "SSE on_connected callback raised: #{e.inspect}"
      end
    end

    # Size caps R4: one WARN per oversized episode (redacted source + cap in
    # bytes), repeats at DEBUG. The episode lasts until an envelope gets
    # through (@oversized cleared in run_loop at the first installed envelope).
    def handle_oversized_event(error)
      where = Quonfig::ConfigLoader.redact_userinfo("#{current_url}/api/v2/sse/config")
      msg = "SSE event from #{where} exceeds the maximum size of #{MAX_EVENT_BYTES} bytes; " \
            'dropping it and backing off (fallback polling will take over)'
      @oversized ? @logger.debug(msg) : @logger.warn(msg)
      @oversized = true
      invoke_on_error(error)
    end

    def handle_error(error)
      if error.is_a?(SSEHTTPAuthError)
        # Already logged once by check_response_status! (R5).
        @logger.debug "SSE Streaming Error: #{error.inspect}"
      else
        @logger.error "SSE Streaming Error: #{error.inspect}"
      end
      invoke_on_error(error)
    end

    # qfg-m3lk: rescue StandardError (NOT Exception) so SystemExit /
    # Interrupt / SignalException still escape — Ctrl-C inside a customer
    # callback must still kill the process. StandardError is the right
    # boundary for "the caller's listener has a bug". Returns the block's
    # value (:updated for an installed envelope), or nil when it raised.
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

    # The stream leg is PINNED to the primary stream URL (sse_api_urls[0])
    # and retried forever with backoff — SSE never fails over (f05 invariant,
    # qfg-41nh.6). Failover is HTTP-poll only: the config-fetch hedge keeps
    # BOTH api_urls legs, but the live stream never repoints to
    # stream.secondary (which is sized for poll rps, not SSE herds, and would
    # silently bind freshness to the mirror). Matches sdk-go's sseClient — a
    # single pinned URL with reconnect backoff (sse_client.go runLoop).
    def current_url
      @prefab_options.sse_api_urls.first
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

    # An auth-class (401/403/404/410) stream response (qfg-goi1.10.26). A
    # subclass of SSEHTTPStatusError so on_error callbacks that only check
    # `is_a?(SSEHTTPStatusError)` keep working. The stream keeps retrying.
    class SSEHTTPAuthError < SSEHTTPStatusError; end

    # @deprecated since 1.8.0: qfg-i5xv's name for SSEHTTPAuthError. The stream
    # no longer stops on these statuses.
    SSEHTTPTerminalError = SSEHTTPAuthError # rubocop:disable Lint/UselessConstantScoping

    # Passed to on_error when a 200 stream ends cleanly before its first valid
    # frame (qfg-goi1.10.43). Not raised.
    class SSEFramelessSessionError < StandardError
      def initialize(msg = 'SSE stream ended before its first frame')
        super
      end
    end

    # Raised by the watchdog into the worker thread when the per-chunk
    # read deadline elapses. Caught by run_loop's rescue, indistinguishable
    # from any other transport error for backoff/restart purposes.
    class SSEReadDeadlineExceeded < StandardError; end

    # Raised by the parser when one event passes MAX_EVENT_BYTES (size caps).
    # Ends the connection as a failed attempt; passed to on_error.
    class SSEEventTooLargeError < StandardError
      def initialize(msg = "SSE event exceeds the maximum size of #{MAX_EVENT_BYTES} bytes")
        super
      end
    end

    # Private: raised from inside +read_body+ when +close+ has been called,
    # so the worker leaves the stream without Net::HTTP draining the body
    # (qfg-yrly). Rescued in +stream_once+; never reaches callers.
    class SSEStopRequested < StandardError; end
    private_constant :SSEStopRequested

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
    #   - +:comment+ lines (keepalives; a comment-only block is a frame)
    #   - multi-line +data:+ (concatenated with +\n+, per spec)
    # Ignores +event:+ and +retry:+ — api-delivery does not emit them and the
    # Quonfig wire contract does not honor reconnect-time directives.
    # Malformed +data:+ JSON is logged and skipped; one bad event does not
    # tear down the stream.
    class EventParser
      # +keepalive_is_frame+: false while the client's oversized gate is set,
      # so only an envelope counts as a frame (size caps).
      def initialize(logger: nil, keepalive_is_frame: true)
        @logger = logger
        @keepalive_is_frame = keepalive_is_frame
        @reader = LineReader.new
        @data = +''
        @have_data = false
        @id = nil
        @saw_comment = false
        @saw_field = false
      end

      # Yields each config envelope. +on_frame+ (optional) is called at every
      # valid frame, before that frame's envelope is yielded. A valid frame is
      # a block ended by a blank line that is either comment-only (the
      # +: keepalive+ heartbeat; +:+ alone counts) or carries +data:+ that
      # decodes and validates as a config envelope. A block cut off by EOF, a
      # malformed or non-envelope data block, an +id:+-only block and a bare
      # blank line are not frames (qfg-goi1.10.43).
      def feed(chunk, on_frame: nil)
        @reader.feed(chunk) do |line|
          if line.empty?
            comment_only = @saw_comment && !@saw_field
            @saw_comment = false
            @saw_field = false
            event = flush
            if event
              on_frame&.call
              yield event
            elsif comment_only && @keepalive_is_frame
              on_frame&.call
            end
          elsif line.start_with?(':')
            @saw_comment = true
          else
            @saw_field = true
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
          # Cap the joined multi-line data (each line is already capped by
          # LineReader).
          if @have_data && @data.bytesize + 1 + rest.bytesize > MAX_EVENT_BYTES
            @data = +''
            @have_data = false
            raise SSEEventTooLargeError
          end

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

        # qfg-9dxb.3: drop a JSON event that is not a config envelope (no meta
        # object with a non-empty version) exactly like malformed JSON — it must
        # never reach install and wipe an established client's keys.
        unless Quonfig::ConfigEnvelope.wire_envelope?(parsed)
          (@logger || LOG).error 'SSE Streaming Error: non-envelope event (missing meta.version); dropped'
          return nil
        end

        meta = parsed['meta'] || {}
        # Skip one malformed config, keep the rest (qfg-krjt); an event with
        # no loadable config is dropped like malformed JSON.
        begin
          configs = Quonfig::ConfigShape.filter(parsed['configs'] || [], logger: @logger || LOG,
                                                                         version: meta['version'])
        rescue Quonfig::ConfigShape::AllInvalidError => e
          (@logger || LOG).error "SSE Streaming Error: #{e.message}; event dropped"
          return nil
        end

        envelope = Quonfig::ConfigEnvelope.new(configs: configs, meta: meta)
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
        # Bytes of @buffer already scanned without finding a terminator, so
        # the next feed resumes there instead of rescanning from byte 0
        # (qfg-goi1.10.2; O(n^2) on a long line in small chunks).
        @scanned = 0
      end

      # Lines are sliced out by position and the consumed prefix is dropped
      # once per feed (in +ensure+, so a raising block does not see a line
      # twice), not once per line.
      def feed(chunk)
        @buffer << chunk.b
        pos = 0
        begin
          loop do
            idx = @buffer.index(/[\r\n]/, [pos, @scanned].max)
            if idx.nil?
              # Size caps: an unterminated line past the cap can never be a
              # valid event; stop here instead of buffering the rest.
              raise SSEEventTooLargeError if @buffer.bytesize - pos > MAX_EVENT_BYTES

              @scanned = @buffer.bytesize
              break
            end
            raise SSEEventTooLargeError if idx - pos > MAX_EVENT_BYTES

            ch = @buffer.getbyte(idx)
            if idx == pos && ch == LF && @last_was_cr
              # Dangling LF of a CRLF pair split across chunks — consume and skip.
              @last_was_cr = false
              pos += 1
              next
            end

            line = @buffer.byteslice(pos, idx - pos).force_encoding('UTF-8')
            consume_to = idx + 1
            @last_was_cr = false
            if ch == CR
              if consume_to == @buffer.bytesize
                # CR at end of buffer — could be CRLF split across feeds.
                @last_was_cr = true
              elsif @buffer.getbyte(consume_to) == LF
                consume_to += 1
              end
            end
            pos = consume_to
            yield line
          end
        ensure
          if pos.positive?
            @buffer = @buffer.byteslice(pos, @buffer.bytesize - pos)
            @scanned = [@scanned - pos, 0].max
          end
        end
      end

      CR = 13
      LF = 10
      private_constant :CR, :LF
    end
  end
end
