# frozen_string_literal: true

module Quonfig
  module Telemetry
    # Owns the background thread that periodically drains the context
    # aggregators and POSTs a JSON telemetry batch to
    # +<telemetry_destination>/api/v1/telemetry/+.
    #
    # Wire shape matches api-telemetry's TelemetryEventsSchema:
    #
    #   {
    #     "instanceHash": "...",
    #     "events": [
    #       { "summaries":       { "start": ..., "end": ..., "summaries": [...] } },
    #       { "contextShapes":   { "shapes":   [...] } },
    #       { "exampleContexts": { "examples": [...] } }
    #     ]
    #   }
    #
    # Auth is HTTP Basic with username "1" and the SDK key as password
    # (matching sdk-node and sdk-go). The +X-Quonfig-SDK-Version+ header
    # carries the +ruby-<VERSION>+ identifier.
    class TelemetryReporter
      LOG = Quonfig::InternalLogger.new(self)

      DEFAULT_INITIAL_DELAY_SECONDS = 8
      DEFAULT_MAX_DELAY_SECONDS = 600

      def initialize(options:, instance_hash:,
                     context_shape_aggregator: nil,
                     example_contexts_aggregator: nil,
                     evaluation_summaries_aggregator: nil,
                     sync_interval: nil,
                     http_connection: nil)
        @options = options
        @instance_hash = instance_hash
        @sdk_key = options.sdk_key
        @telemetry_destination = options.telemetry_destination
        @context_shape_aggregator = context_shape_aggregator
        @example_contexts_aggregator = example_contexts_aggregator
        @evaluation_summaries_aggregator = evaluation_summaries_aggregator
        @http_connection = http_connection
        @sync_interval = calculate_sync_interval(sync_interval)
        @stopped = Concurrent::AtomicBoolean.new(false)
        @thread = nil
        @at_exit_registered = false
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
        return if context.nil?

        @context_shape_aggregator&.push(context)
        @example_contexts_aggregator&.record(context)
      end

      def record_evaluation(**kwargs)
        @evaluation_summaries_aggregator&.record(**kwargs)
      end

      def start
        return if @thread&.alive?
        return unless enabled?

        @stopped.make_false
        register_at_exit_handler
        @thread = Thread.new do
          Thread.current.name = 'quonfig-telemetry-reporter'
          LOG.debug "Telemetry reporter started instance_hash=#{@instance_hash} destination=#{@telemetry_destination}"

          until @stopped.true?
            begin
              sleep_duration = @sync_interval.call
              slept = 0.0
              step = 0.5
              while slept < sleep_duration && !@stopped.true?
                sleep([step, sleep_duration - slept].min)
                slept += step
              end
              break if @stopped.true?

              sync
            rescue StandardError => e
              LOG.warn "[quonfig] Telemetry reporter error: #{e.class}: #{e.message}"
            end
          end
        end
      end

      def stop
        @stopped.make_true
        thread = @thread
        @thread = nil
        thread&.wakeup if thread&.alive?
        # Final drain attempt on stop so tests / short-lived processes
        # don't silently drop pending telemetry.
        begin
          sync
        rescue StandardError => e
          LOG.debug "[quonfig] Final telemetry sync failed: #{e.class}: #{e.message}"
        end
      end

      # Drain all aggregators and POST the batch. Public so tests can
      # trigger a sync without waiting for the background loop.
      def sync
        events = []
        if (summaries_event = @evaluation_summaries_aggregator&.drain_event)
          events << summaries_event
        end
        if (shape_event = @context_shape_aggregator&.drain_event)
          events << shape_event
        end
        if (example_event = @example_contexts_aggregator&.drain_event)
          events << example_event
        end

        return if events.empty?

        payload = {
          'instanceHash' => @instance_hash,
          'events' => events
        }

        post(payload)
      end

      # Visible for tests.
      def at_exit_registered?
        @at_exit_registered
      end

      private

      # Rails / Passenger / Puma workers often terminate via SIGTERM without
      # a chance to call Client#stop. Register a Kernel.at_exit hook on
      # first start so the in-flight batch still gets flushed.
      def register_at_exit_handler
        return if @at_exit_registered

        Kernel.at_exit { final_drain_on_exit }
        @at_exit_registered = true
      end

      # Wait this long for the background reporter thread to exit before
      # giving up. Bounded so a thread blocked on a dead telemetry endpoint
      # can't hang process exit.
      AT_EXIT_THREAD_JOIN_TIMEOUT_SECONDS = 1.0

      # Idempotent final drain. Safe to call after #stop has already
      # drained: aggregators return nil when empty and #sync becomes a
      # no-op. Bounded so a stuck reporter thread or dead telemetry
      # endpoint can't hang process exit.
      def final_drain_on_exit
        @stopped.make_true
        thread = @thread
        @thread = nil
        if thread&.alive?
          thread.wakeup
          thread.join(AT_EXIT_THREAD_JOIN_TIMEOUT_SECONDS)
        end
        sync
      rescue StandardError => e
        LOG.debug "[quonfig] at_exit telemetry drain failed: #{e.class}: #{e.message}"
      end

      def post(payload)
        conn = http_connection
        return if conn.nil?

        response = conn.post('/api/v1/telemetry/', payload)
        status = response.respond_to?(:status) ? response.status : nil
        if status && status >= 400
          LOG.warn "[quonfig] Telemetry POST failed: #{status}"
        else
          LOG.debug "[quonfig] Telemetry POST ok: events=#{payload['events'].size}"
        end
        response
      end

      def http_connection
        @http_connection ||= begin
          return nil if @sdk_key.nil? || @telemetry_destination.nil?

          Quonfig::HttpConnection.new(@telemetry_destination, @sdk_key)
        end
      end

      def calculate_sync_interval(sync_interval)
        return proc { sync_interval } if sync_interval.is_a?(Numeric)
        return sync_interval if sync_interval.respond_to?(:call)

        Quonfig::ExponentialBackoff.new(
          initial_delay: DEFAULT_INITIAL_DELAY_SECONDS,
          max_delay: DEFAULT_MAX_DELAY_SECONDS,
          multiplier: 1.5
        )
      end
    end
  end
end
