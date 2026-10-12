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
      # Bound on the once-per-hour rate-limit map (P6 of the telemetry
      # transport policy, qfg-y8je.8): a new key arriving when it is full
      # prunes expired entries, and is not recorded if it is still full.
      SEEN_CAP = 100_000

      # Max nesting depth copied from a context value; deeper levels are left
      # out. Guards the recursive copy against stack exhaustion.
      MAX_SNAPSHOT_DEPTH = 32

      attr_reader :data, :cache

      def initialize(max_contexts:, rate_limit_seconds: ONE_HOUR_SECONDS, seen_cap: SEEN_CAP)
        @max_contexts = max_contexts
        @seen_cap = seen_cap
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
        return unless room_in_cache?

        @cache.set(key)
        @data.push([Quonfig::TimeHelpers.now_in_ms, snapshot(context)])
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
        return nil if @data.empty?

        to_ship = prepare_data

        examples = to_ship.map do |timestamp_ms, context|
          contexts_list = contexts_to_list(context)
          { 'timestamp' => timestamp_ms, 'contextSet' => { 'contexts' => contexts_list } }
        end

        { 'exampleContexts' => { 'examples' => examples } }
      end

      private

      # Copy +context+ into plain JSON-safe data at record time (qfg-goi1.2.35).
      # The caller owns its nested Hashes/Arrays and may mutate them after
      # get() returns, while the window is serialized later on the reporter
      # thread. NaN/Infinity become nil, and an edge that closes a cycle is
      # left out, so one bad value no longer makes JSON.generate raise and drop
      # the whole window. Any other object is rendered with #to_s, which is
      # what JSON.generate already sent for it (a UUID-like key keeps the
      # example reportable); one whose #to_s raises is left out.
      def snapshot(context)
        named = contexts_to_list(context)
        named.to_h { |entry| [entry['type'], snapshot_value(entry['values'], 0, {})] }
      end

      def room_in_cache?
        return true if @cache.data.size < @seen_cap

        @cache.prune
        @cache.data.size < @seen_cap
      end

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

      OMIT = Object.new.freeze
      private_constant :OMIT

      def snapshot_value(value, depth, ancestors)
        case value
        when nil, true, false, Integer then value
        when Float then value.finite? ? value : nil
        when String then value.frozen? ? value : value.dup
        when Symbol then value.to_s
        when Hash, Array then snapshot_container(value, depth, ancestors)
        else value.to_s
        end
      rescue StandardError
        OMIT
      end

      # +ancestors+ holds the containers on the current path only, so the same
      # value reached twice without a cycle is still copied both times.
      def snapshot_container(value, depth, ancestors)
        id = value.object_id
        return OMIT if depth >= MAX_SNAPSHOT_DEPTH || ancestors.key?(id)

        ancestors[id] = true
        begin
          if value.is_a?(Hash)
            value.each_with_object({}) do |(k, v), acc|
              copied = snapshot_value(v, depth + 1, ancestors)
              acc[k.to_s] = copied unless copied.equal?(OMIT)
            end
          else
            value.map { |v| snapshot_value(v, depth + 1, ancestors) }.reject { |v| v.equal?(OMIT) }
          end
        ensure
          ancestors.delete(id)
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
