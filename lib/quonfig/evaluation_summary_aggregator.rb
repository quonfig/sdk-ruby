# frozen_string_literal: true

require_relative 'periodic_sync'

module Quonfig
  # This class aggregates the number of times each config is evaluated, and
  # details about how the config is evaluated This data is reported to the
  # server at a regular interval defined by `sync_interval`.
  class EvaluationSummaryAggregator
    include Quonfig::PeriodicSync
    LOG = Quonfig::InternalLogger.new(self)

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

    def counter_proto(counter, count)
      PrefabProto::ConfigEvaluationCounter.new(
        config_id: counter[:config_id],
        selected_index: counter[:selected_index],
        config_row_index: counter[:config_row_index],
        conditional_value_index: counter[:conditional_value_index],
        weighted_value_index: counter[:weighted_value_index],
        selected_value: counter[:selected_value],
        count: count
      )
    end

    def flush(to_ship, start_at_was)
      pool.post do
        LOG.debug "Flushing #{to_ship.size} summaries"

        summaries_proto = PrefabProto::ConfigEvaluationSummaries.new(
          start: start_at_was,
          end: Quonfig::TimeHelpers.now_in_ms,
          summaries: summaries(to_ship)
        )

        result = post('/api/v1/telemetry', events(summaries_proto))

        LOG.debug "Uploaded #{to_ship.size} summaries: #{result.status}"
      end
    end

    def events(summaries)
      event = PrefabProto::TelemetryEvent.new(summaries: summaries)

      PrefabProto::TelemetryEvents.new(
        instance_hash: @client.instance_hash,
        events: [event]
      )
    end

    def summaries(data)
      data.map do |(config_key, config_type), counters|
        counter_protos = counters.map { |counter, count| counter_proto(counter, count) }

        PrefabProto::ConfigEvaluationSummary.new(
          key: config_key,
          type: config_type,
          counters: counter_protos
        )
      end
    end
  end
end
