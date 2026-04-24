# frozen_string_literal: true

module Quonfig
  module Telemetry
    # Accumulates per-evaluation counts grouped by (config_key, config_type),
    # with one counter per unique (config_id, conditional_value_index,
    # weighted_value_index, selected_value). Emits api-telemetry's
    # `summaries` event — JSON wire format matching sdk-node and sdk-go.
    #
    # Ported from ReforgeHQ/sdk-ruby evaluation_summary_aggregator.rb and
    # adapted to the JSON wire format (EvaluationSummariesSchema in
    # api-telemetry/src/telemetry-schemas.ts).
    class EvaluationSummariesAggregator
      attr_reader :data

      def initialize(max_keys:)
        @max_keys = max_keys
        @data = Concurrent::Hash.new
        @start_at_ms = nil
        @mutex = Mutex.new
      end

      # Record a single evaluation.
      #
      # @param config_id [String]
      # @param config_key [String]
      # @param config_type [String, nil] "config", "feature_flag", etc.
      #   "log_level" evaluations are intentionally dropped (they're high
      #   volume and not useful for usage analytics).
      # @param conditional_value_index [Integer] rule index
      # @param weighted_value_index [Integer, nil]
      # @param selected_value [Object] the unwrapped evaluated value
      # @param reason [Integer] wire reason code (see Quonfig::Reason::WIRE_*)
      def record(config_id:, config_key:, config_type:,
                 conditional_value_index:, weighted_value_index: nil,
                 selected_value: nil, reason: 0)
        return if @max_keys <= 0
        return if config_type == 'log_level'

        group_key = [config_key, config_type]
        counter_key = [config_id, conditional_value_index, weighted_value_index, selected_value]

        @mutex.synchronize do
          unless @data.key?(group_key)
            return if @data.size >= @max_keys

            @data[group_key] = {}
          end
          @start_at_ms ||= Quonfig::TimeHelpers.now_in_ms

          bucket = @data[group_key]
          bucket[counter_key] ||= { count: 0, reason: reason }
          bucket[counter_key][:count] += 1
        end
      end

      # Drain accumulated summaries into a single telemetry event payload.
      # Returns +nil+ when there is nothing to ship.
      def drain_event
        snapshot = nil
        start_at = nil

        @mutex.synchronize do
          return nil if @data.empty?

          snapshot = @data
          start_at = @start_at_ms
          @data = Concurrent::Hash.new
          @start_at_ms = nil
        end

        summaries = snapshot.map do |(config_key, config_type), counters|
          counter_list = counters.map do |(config_id, cvi, wvi, sval), meta|
            counter = {
              'configId' => config_id,
              'conditionalValueIndex' => cvi,
              'configRowIndex' => 0,
              'selectedValue' => wrap_selected_value(sval),
              'count' => meta[:count],
              'reason' => meta[:reason]
            }
            counter['weightedValueIndex'] = wvi unless wvi.nil?
            counter
          end

          entry = { 'key' => config_key, 'counters' => counter_list }
          entry['type'] = config_type unless config_type.nil?
          entry
        end

        {
          'summaries' => {
            'start' => start_at || Quonfig::TimeHelpers.now_in_ms,
            'end' => Quonfig::TimeHelpers.now_in_ms,
            'summaries' => summaries
          }
        }
      end

      private

      # Wrap the evaluated value in the Prefab-proto-style tagged hash that
      # api-telemetry ClickHouse ingestion expects. Keys match sdk-go's
      # marshalSelectedValue (proto field names): bool / int / double /
      # string / stringList.
      def wrap_selected_value(value)
        case value
        when true, false then { 'bool' => value }
        when Integer     then { 'int' => value }
        when Float       then { 'double' => value }
        when String      then { 'string' => value }
        when Array       then { 'stringList' => value.map(&:to_s) }
        when nil         then { 'string' => '' }
        else                  { 'string' => value.to_s }
        end
      end
    end
  end
end
