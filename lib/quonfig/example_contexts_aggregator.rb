# frozen_string_literal: true

require_relative 'periodic_sync'

module Quonfig
  # Aggregates example contexts, deduped per grouped-key, and flushes them as
  # telemetry to POST /api/v1/telemetry/ as a single consolidated JSON body
  # (see api-telemetry TelemetryEventsSchema). The same grouped key is never
  # shipped more than once per hour.
  class ExampleContextsAggregator
    include Quonfig::PeriodicSync
    LOG = Quonfig::InternalLogger.new(self)

    TELEMETRY_PATH = '/api/v1/telemetry/'
    ONE_HOUR = 60 * 60

    attr_reader :data, :cache

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

        payload = {
          instanceHash: @client.instance_hash,
          events: [
            {
              exampleContexts: {
                examples: examples_json(to_ship)
              }
            }
          ]
        }

        result = post(TELEMETRY_PATH, payload)

        LOG.debug "Uploaded #{to_ship.size} examples: #{result.status}"
      end
    end

    def examples_json(to_ship)
      to_ship.map do |contexts|
        {
          timestamp: contexts.seen_at * 1000,
          contextSet: {
            contexts: contexts.contexts.map { |_, named| { type: named.name, values: named.to_h } }
          }
        }
      end
    end
  end
end
