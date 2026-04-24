# frozen_string_literal: true

module Quonfig
  module Telemetry
    # Samples *example* contexts seen during evaluation. Dedupes by the
    # concatenation of each named context's "key" property and rate-limits
    # each grouped key to once per hour.
    #
    # Emits api-telemetry's `exampleContexts` event — JSON wire format,
    # matching sdk-node and sdk-go. This is NOT the old Prefab protobuf.
    class ExampleContextsAggregator
      ONE_HOUR_SECONDS = 60 * 60

      attr_reader :data, :cache

      def initialize(max_contexts:, rate_limit_seconds: ONE_HOUR_SECONDS)
        @max_contexts = max_contexts
        @data = Concurrent::Array.new
        @cache = Quonfig::RateLimitCache.new(rate_limit_seconds)
      end

      # Record a context for possible emission. Expects a Quonfig::Context.
      # Contexts with no grouped_key (nothing to dedupe on) are dropped to
      # avoid shipping empty/anonymous samples.
      def record(context)
        return if @max_contexts <= 0
        return if context.nil?

        key = grouped_key_for(context)
        return if key.nil? || key.empty?

        return unless @data.size < @max_contexts && !@cache.fresh?(key)

        @cache.set(key)
        @data.push([Quonfig::TimeHelpers.now_in_ms, context])
      end

      def prepare_data
        to_ship = @data.dup
        @data.clear
        @cache.prune
        to_ship
      end

      # Drain accumulated examples into a single telemetry event payload
      # matching api-telemetry's ExampleContextsSchema, or +nil+ if empty.
      def drain_event
        return nil if @data.size.zero?

        to_ship = prepare_data

        examples = to_ship.map do |timestamp_ms, context|
          contexts_list = contexts_to_list(context)
          { 'timestamp' => timestamp_ms, 'contextSet' => { 'contexts' => contexts_list } }
        end

        { 'exampleContexts' => { 'examples' => examples } }
      end

      private

      def grouped_key_for(context)
        return context.grouped_key if context.respond_to?(:grouped_key)

        # Fallback for plain-Hash contexts: concatenate each named context's
        # "key" (or "trackingId") value.
        return nil unless context.is_a?(Hash)

        context.values.map do |ctx|
          next nil unless ctx.is_a?(Hash)

          ctx['key'] || ctx[:key] || ctx['trackingId'] || ctx[:trackingId]
        end.compact.map(&:to_s).reject(&:empty?).sort.join('|')
      end

      def contexts_to_list(context)
        if context.respond_to?(:contexts)
          context.contexts.map do |name, named|
            values = named.respond_to?(:to_h) ? named.to_h : named
            { 'type' => name.to_s, 'values' => stringify_values(values) }
          end
        elsif context.is_a?(Hash)
          context.map do |name, values|
            values = { name.to_s => values } unless values.is_a?(Hash)
            { 'type' => name.to_s, 'values' => stringify_values(values) }
          end
        else
          []
        end
      end

      def stringify_values(hash)
        return {} unless hash.is_a?(Hash)

        hash.each_with_object({}) do |(k, v), acc|
          acc[k.to_s] = v
        end
      end
    end
  end
end
