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
                     sync_interval: nil,
                     http_connection: nil)
        @options = options
        @instance_hash = instance_hash
        @sdk_key = options.sdk_key
        @telemetry_destination = options.telemetry_destination
        @context_shape_aggregator = context_shape_aggregator
        @example_contexts_aggregator = example_contexts_aggregator
        @http_connection = http_connection
        @sync_interval = calculate_sync_interval(sync_interval)
        @stopped = Concurrent::AtomicBoolean.new(false)
        @thread = nil
      end

      def enabled?
        return false if @sdk_key.nil? || @sdk_key.to_s.empty?
        return false if @telemetry_destination.nil? || @telemetry_destination.to_s.empty?

        !@context_shape_aggregator.nil? || !@example_contexts_aggregator.nil?
      end

      # Record a context across all active aggregators.
      def record(context)
        return if context.nil?

        @context_shape_aggregator&.push(context)
        @example_contexts_aggregator&.record(context)
      end

      def start
        return if @thread&.alive?
        return unless enabled?

        @stopped.make_false
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

      private

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
