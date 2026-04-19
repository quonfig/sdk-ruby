# frozen_string_literal: true

require_relative 'periodic_sync'

module Quonfig
  # This class aggregates example contexts. It dedupes based on the
  # concatenation of the keys of the contexts.
  #
  # It shouldn't send the same context more than once per hour.
  class ExampleContextsAggregator
    include Quonfig::PeriodicSync
    LOG = Quonfig::InternalLogger.new(self)

    attr_reader :data, :cache

    ONE_HOUR = 60 * 60

    def initialize(client:, max_contexts:, sync_interval:)
      @client = client
      @max_contexts = max_contexts
      @name = 'example_contexts_aggregator'

      @data = Concurrent::Array.new
      @cache = Quonfig::RateLimitCache.new(ONE_HOUR)

      start_periodic_sync(sync_interval)
    end

    def record(contexts)
      key = contexts.grouped_key

      return unless @data.size < @max_contexts && !@cache.fresh?(key)

      @cache.set(key)

      @data.push(contexts)
    end

    private

    def on_prepare_data
      @cache.prune
    end

    def flush(to_ship, _)
      pool.post do
        LOG.debug "Flushing #{to_ship.size} examples"

        result = post('/api/v1/telemetry', events(to_ship))

        LOG.debug "Uploaded #{to_ship.size} examples: #{result.status}"
      end
    end

    def example_contexts(to_ship)
      to_ship.map do |contexts|
        PrefabProto::ExampleContext.new(
          timestamp: contexts.seen_at * 1000,
          contextSet: contexts.slim_proto
        )
      end
    end

    def events(to_ship)
      event = PrefabProto::TelemetryEvent.new(
        example_contexts: PrefabProto::ExampleContexts.new(
          examples: example_contexts(to_ship)
        )
      )

      PrefabProto::TelemetryEvents.new(
        instance_hash: @client.instance_hash,
        events: [event]
      )
    end
  end
end
