# frozen_string_literal: true

require_relative 'periodic_sync'

module Quonfig
  # Aggregates per-config evaluation counts and flushes them as telemetry to
  # POST /api/v1/telemetry/ as a single consolidated JSON body (see api-telemetry
  # TelemetryEventsSchema).
  class EvaluationSummaryAggregator
    include Quonfig::PeriodicSync
    LOG = Quonfig::InternalLogger.new(self)

    TELEMETRY_PATH = '/api/v1/telemetry/'

    attr_reader :data

    def initialize(client:, max_keys:, sync_interval:)
      @client = client
      @max_keys = max_keys
      @name = 'evaluation_summary_aggregator'

      @data = Concurrent::Hash.new

      start_periodic_sync(sync_interval)
    end

    def record(config_key:, config_type:, counter:)
      return if @data.size >= @max_keys

      key = [config_key, config_type]
      @data[key] ||= Concurrent::Hash.new

      @data[key][counter] ||= 0
      @data[key][counter] += 1
    end

    private

    def flush(to_ship, start_at_was)
      pool.post do
        LOG.debug "Flushing #{to_ship.size} summaries"

        payload = {
          instanceHash: @client.instance_hash,
          events: [
            {
              summaries: {
                start: start_at_was,
                end: Quonfig::TimeHelpers.now_in_ms,
                summaries: summaries_json(to_ship)
              }
            }
          ]
        }

        result = post(TELEMETRY_PATH, payload)

        LOG.debug "Uploaded #{to_ship.size} summaries: #{result.status}"
      end
    end

    def summaries_json(to_ship)
      to_ship.map do |(config_key, config_type), counters|
        {
          key: config_key,
          type: config_type.to_s,
          counters: counters.map { |counter, count| counter_json(counter, count) }
        }
      end
    end

    def counter_json(counter, count)
      out = {
        configId: counter[:config_id],
        conditionalValueIndex: counter[:conditional_value_index],
        configRowIndex: counter[:config_row_index],
        selectedValue: counter[:selected_value],
        count: count
      }
      out[:reason] = counter[:reason] if counter.key?(:reason)
      out[:weightedValueIndex] = counter[:weighted_value_index] unless counter[:weighted_value_index].nil?
      out
    end
  end
end
