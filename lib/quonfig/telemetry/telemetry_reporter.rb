# frozen_string_literal: true

require 'json'

module Quonfig
  module Telemetry
    # Owns the background thread that drains the aggregators once per tick and
    # hands the serialized window to a TransportQueue, which retains failed
    # batches byte-for-byte and resends them under the telemetry transport
    # policy (qfg-y8je.8: 60s ticks, one POST in flight, 15s timeout / 5s
    # connect, 30s floor after a failure, Retry-After up to 10 min,
    # 5 batches / 2MB / 5 min retention, disable on 401/403/404; see
    # TransportQueue).
    #
    # Wire shape matches api-telemetry's TelemetryEventsSchema:
    #
    #   {
    #     "instanceHash": "...",
    #     "events": [
    #       { "summaries":       { "start": ..., "end": ..., "summaries": [...] } },
    #       { "contextShapes":   { "shapes":   [...] } },
    #       { "exampleContexts": { "examples": [...] } },
    #       { "failover":        { "start": ..., "end": ..., "hedgeFired": ..., ... } }
    #     ]
    #   }
    #
    # Auth is HTTP Basic with username "1" and the SDK key as password
    # (matching sdk-node and sdk-go). The +X-Quonfig-SDK-Version+ header
    # carries the +ruby-<VERSION>+ identifier.
    class TelemetryReporter
      LOG = Quonfig::InternalLogger.new(self)

      TELEMETRY_PATH = '/api/v1/telemetry/'
      BODY_SNIPPET_BYTES = 1024
      private_constant :BODY_SNIPPET_BYTES

      # Build the aggregators the options enable and a reporter over them, or
      # nil when every collector is off. Client#initialize_telemetry uses this;
      # +clock+ is a test seam (defaults to the monotonic clock).
      def self.build(options:, instance_hash:, failover_aggregator: nil, clock: nil)
        shapes = (ContextShapeAggregator.new(max_shapes: options.collect_max_shapes) if options.collect_max_shapes.to_i.positive?)
        examples = (ExampleContextsAggregator.new(max_contexts: options.collect_max_example_contexts) if options.collect_max_example_contexts.to_i.positive?)
        summaries = (EvaluationSummariesAggregator.new(max_keys: options.collect_max_evaluation_summaries) if options.collect_max_evaluation_summaries.to_i.positive?)
        return nil if shapes.nil? && examples.nil? && summaries.nil?

        new(
          options: options,
          instance_hash: instance_hash,
          context_shape_aggregator: shapes,
          example_contexts_aggregator: examples,
          evaluation_summaries_aggregator: summaries,
          failover_aggregator: failover_aggregator,
          clock: clock
        )
      end

      # Resolved transport settings (the +telemetry_*+ options and
      # +collect_sync_interval+). +flush_interval_ms+ is nil when the interval
      # is a callable.
      attr_reader :config

      # +sync_interval+ (seconds, or a callable returning seconds) defaults to
      # +options.collect_sync_interval+ (60). +http_connection+ is a test seam:
      # anything answering +post(path, body_string)+ with a response that has
      # +status+.
      def initialize(options:, instance_hash:,
                     context_shape_aggregator: nil,
                     example_contexts_aggregator: nil,
                     evaluation_summaries_aggregator: nil,
                     failover_aggregator: nil,
                     sync_interval: nil,
                     http_connection: nil,
                     clock: nil)
        @options = options
        @instance_hash = instance_hash
        @sdk_key = options.sdk_key
        @telemetry_destination = options.telemetry_destination
        @context_shape_aggregator = context_shape_aggregator
        @example_contexts_aggregator = example_contexts_aggregator
        @evaluation_summaries_aggregator = evaluation_summaries_aggregator
        # Failover counters carry no user data and are the operational signal for
        # the secondary-delivery hardening (qfg-41nh.18), so they ride the
        # existing telemetry stream. The ConfigLoader records directly into this
        # aggregator at the failover call sites; the reporter only drains it.
        @failover_aggregator = failover_aggregator
        @http_connection = http_connection
        @sync_interval = sync_interval.nil? ? options.collect_sync_interval : sync_interval
        @config = {
          flush_interval_ms: @sync_interval.is_a?(Numeric) ? (@sync_interval * 1000).to_i : nil,
          timeout_ms: options.telemetry_timeout_ms,
          connect_timeout_ms: options.telemetry_connect_timeout_ms,
          max_retained_batches: options.telemetry_max_retained_batches,
          max_retained_bytes: options.telemetry_max_retained_bytes,
          max_retained_age_ms: options.telemetry_max_retained_age_ms
        }.freeze
        @queue = TransportQueue.new(
          sender: method(:post_batch),
          telemetry_url: "#{@telemetry_destination}#{TELEMETRY_PATH}",
          timeout_ms: @config[:timeout_ms],
          max_retained_batches: @config[:max_retained_batches],
          max_retained_bytes: @config[:max_retained_bytes],
          max_retained_age_ms: @config[:max_retained_age_ms],
          clock: clock || MonotonicClock,
          on_disabled: method(:on_disabled)
        )
        # Held for a whole tick (serialize + drain), so at most one POST is in
        # flight (P2); a tick that finds it held is skipped.
        @tick_mutex = Mutex.new
        @state_mutex = Mutex.new
        @wake = ConditionVariable.new
        @closed = false
        @thread = nil
        @at_exit_registered = false
        # Set on #start. Everything that can EMIT is gated on it so a forked
        # child never speaks for the process that created this reporter.
        @owner_pid = nil
      end

      def enabled?
        return false if @sdk_key.nil? || @sdk_key.to_s.empty?
        return false if @telemetry_destination.nil? || @telemetry_destination.to_s.empty?

        !@context_shape_aggregator.nil? ||
          !@example_contexts_aggregator.nil? ||
          !@evaluation_summaries_aggregator.nil?
      end

      # Record a context across the context-driven aggregators. Evaluation
      # summaries are recorded separately via
      # +record_evaluation(...)+ since they require the evaluation result.
      def record(context)
        return if context.nil? || @queue.disabled?

        @context_shape_aggregator&.push(context)
        @example_contexts_aggregator&.record(context)
      end

      def record_evaluation(**kwargs)
        return if @queue.disabled?

        @evaluation_summaries_aggregator&.record(**kwargs)
      end

      def start
        return if @thread&.alive?
        return unless enabled?
        return if @closed || @queue.disabled?

        # Claim ownership for THIS process. fork(2) copies the reporter, its
        # aggregators, and the process-wide at_exit closure registered below;
        # the pid recorded here is what lets the copy know it is not the
        # owner and must stay silent (qfg-lv4n.1, dd-trace-rb's pattern).
        @owner_pid = Process.pid
        register_at_exit_handler
        @thread = Thread.new do
          Thread.current.name = 'quonfig-telemetry-reporter'
          LOG.debug "Telemetry reporter started instance_hash=#{@instance_hash} destination=#{@telemetry_destination}"
          run_loop
        end
      end

      # One tick of the contract's model: skip if closed, disabled or a POST is
      # in flight (P2; the live window keeps aggregating); expire aged batches;
      # skip if the 30s floor or Retry-After has not elapsed; serialize the
      # live window once and append it; drain oldest-first.
      def tick
        return if foreign_process?('tick')
        return unless @tick_mutex.try_lock

        begin
          run_tick
        ensure
          @tick_mutex.unlock
        end
      end

      # Send the live window now. Waits for an in-flight POST first (bounded by
      # the request timeout), then runs a tick, so after a failure it respects
      # the 30s floor and Retry-After. Never raises.
      #
      # Silent in any process other than the one that started the reporter:
      # after a fork the child holds a full copy of the PARENT's un-flushed
      # window, and the parent is still going to flush it itself.
      def flush
        return if foreign_process?('sync')

        @tick_mutex.synchronize { run_tick }
      rescue StandardError => e
        LOG.debug "Telemetry flush failed: #{e.class}: #{e.message}"
      end
      alias sync flush

      # Shutdown (P8): stop the reporter thread (aborting an in-flight POST),
      # then give the live window one POST with a 5s deadline. The retained
      # queue is not drained. Idempotent; never raises; never blocks exit for
      # longer than that deadline.
      def close
        return if foreign_process?('close')

        thread = @state_mutex.synchronize do
          return if @closed

          @closed = true
          current = @thread
          @thread = nil
          current
        end
        stop_thread(thread)
        return if @queue.disabled?

        body = serialize_window
        return if body.nil?

        @queue.send_final(body, [TransportQueue::SHUTDOWN_FLUSH_DEADLINE_MS, @config[:timeout_ms]].min)
      rescue StandardError => e
        LOG.debug "Telemetry close failed: #{e.class}: #{e.message}"
      end
      alias stop close

      # Test-visible state (the contract's retained_count / retained_bytes /
      # telemetry_enabled).
      def debug_state
        {
          retained_count: @queue.retained_count,
          retained_bytes: @queue.retained_bytes,
          enabled: !@queue.disabled?,
          in_flight: @queue.in_flight?,
          thread_alive: @thread&.alive? || false
        }
      end

      # Visible for tests.
      def at_exit_registered?
        @at_exit_registered
      end

      # Pid of the process that started this reporter, or nil if it was never
      # started. Visible for tests / diagnostics.
      attr_reader :owner_pid

      # Called on the INHERITED reporter in a forked child, from
      # +Quonfig::Client#after_fork_in_child+, once the child has dropped its
      # reference to it. Makes the copied window unreachable so nothing can
      # ever emit it — belt to the +@owner_pid+ braces.
      #
      # Deliberately does NOT stop, close, or join anything: the thread does
      # not exist in the child, and the HTTP connection's fd is shared with
      # the parent.
      def discard_inherited!
        @closed = true
        @thread = nil
        @context_shape_aggregator = nil
        @example_contexts_aggregator = nil
        @evaluation_summaries_aggregator = nil
        @failover_aggregator = nil
      end

      private

      def run_tick
        return if @closed || @queue.disabled?

        @queue.expire
        return unless @queue.send_allowed?

        body = serialize_window
        @queue.append(body) if body
        @queue.drain
      end

      # Fixed cadence: tick k fires at k * interval regardless of how long a
      # drain takes. The interval never grows (the old exponential backoff,
      # which grew even on success, is gone: P4).
      def run_loop
        next_at = MonotonicClock.now_ms + next_interval_ms
        until loop_done?
          wait_ms = next_at - MonotonicClock.now_ms
          if wait_ms.positive?
            @state_mutex.synchronize { @wake.wait(@state_mutex, wait_ms / 1000.0) unless loop_done? }
            next
          end
          next_at += next_interval_ms
          next_at = MonotonicClock.now_ms + next_interval_ms if next_at <= MonotonicClock.now_ms
          begin
            tick
          rescue StandardError => e
            LOG.debug "Telemetry tick failed: #{e.class}: #{e.message}"
          end
        end
      end

      def loop_done?
        @closed || @queue.disabled?
      end

      def next_interval_ms
        seconds = @sync_interval.respond_to?(:call) ? @sync_interval.call : @sync_interval
        [(seconds.to_f * 1000).to_i, 1].max
      end

      def wake_thread
        @state_mutex.synchronize { @wake.broadcast }
      end

      # Stop the reporter thread. A thread parked in its wait exits on the
      # broadcast; one still busy (a POST in flight) is killed, which aborts
      # the POST like sdk-node's close() does. The aborted batch is never resent.
      def stop_thread(thread)
        return if thread.nil? || thread == Thread.current || !thread.alive?

        wake_thread
        thread.kill unless thread.join(0.1)
      end

      def on_disabled
        # Nothing aggregates for a dead endpoint: drop what the window holds.
        serialize_window
        wake_thread
      end

      # Drain the aggregators into one serialized payload. This is the only
      # serialization: the queue stores and resends these exact bytes (P5, P9).
      def serialize_window
        events = [
          @evaluation_summaries_aggregator&.drain_event,
          @context_shape_aggregator&.drain_event,
          @example_contexts_aggregator&.drain_event,
          # nil unless the window saw failover activity.
          @failover_aggregator&.drain_event
        ].compact
        return nil if events.empty?

        JSON.generate('instanceHash' => @instance_hash, 'events' => events)
      end

      # The TransportQueue sender: one POST of +body+ verbatim.
      def post_batch(body, timeout_ms)
        response = telemetry_connection(timeout_ms).post(TELEMETRY_PATH, body)
        headers = response.respond_to?(:headers) ? response.headers : nil
        snippet = response.respond_to?(:body) ? response.body.to_s.byteslice(0, BODY_SNIPPET_BYTES) : ''
        TransportQueue::Result.new(
          status: response.status.to_i,
          retry_after: headers && headers['retry-after'],
          body_snippet: snippet
        )
      end

      # A connection bounded by +timeout_ms+ overall and the connect timeout
      # (never longer than +timeout_ms+) for TCP connect + TLS (P1).
      def telemetry_connection(timeout_ms)
        return @http_connection if @http_connection

        Quonfig::HttpConnection.new(
          @telemetry_destination, @sdk_key,
          timeout_ms: timeout_ms,
          open_timeout_ms: [@config[:connect_timeout_ms], timeout_ms].min
        )
      end

      # True when this reporter belongs to a different process — i.e. we are
      # a fork(2) copy. Never true before #start (nothing has been claimed,
      # and nothing was registered at_exit either).
      def foreign_process?(operation)
        return false if @owner_pid.nil?
        return false if @owner_pid == Process.pid

        LOG.debug "[quonfig] Telemetry #{operation} skipped in forked child " \
                  "pid=#{Process.pid} owner_pid=#{@owner_pid}"
        true
      end

      # Rails / Passenger / Puma workers often terminate via SIGTERM without
      # a chance to call Client#stop. Register a Kernel.at_exit hook on
      # first start so the live window still gets its one final flush.
      def register_at_exit_handler
        return if @at_exit_registered

        Kernel.at_exit { final_drain_on_exit }
        @at_exit_registered = true
      end

      # Idempotent final flush (#close). Safe after #stop: a second close is a
      # no-op. Bounded by the 5s shutdown deadline, so a dead telemetry
      # endpoint can't hang process exit.
      def final_drain_on_exit
        close
      end
    end
  end
end
