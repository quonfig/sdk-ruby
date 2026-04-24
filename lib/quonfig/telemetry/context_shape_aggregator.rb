# frozen_string_literal: true

module Quonfig
  module Telemetry
    # Aggregates the set of context shapes observed during config
    # evaluation. Each unique (context-name, property, type) tuple is
    # stored once. On sync, the set is folded into a hash grouped by
    # context name and emitted as api-telemetry's `contextShapes` event.
    #
    # Matches the sdk-node/sdk-go JSON wire format — NOT the old
    # Prefab protobuf serialization.
    class ContextShapeAggregator
      attr_reader :data

      def initialize(max_shapes:)
        @max_shapes = max_shapes
        @data = Concurrent::Set.new
      end

      # Record every property of every named context in +context+.
      # +context+ may be a Quonfig::Context or a bare Hash
      # ({ 'user' => { 'key' => ..., 'email' => ... }, ... }).
      def push(context)
        return if @max_shapes <= 0
        return if context.nil?
        return if @data.size >= @max_shapes

        each_named_context(context) do |name, hash|
          next unless hash.is_a?(Hash)

          hash.each_pair do |key, value|
            next if @data.size >= @max_shapes

            @data.add [name.to_s, key.to_s, Quonfig::Telemetry::ContextShape.field_type_number(value)]
          end
        end
      end

      # Fold the raw tuples into { name => { key => type, ... }, ... }.
      # Clears the underlying set.
      def prepare_data
        duped = @data.dup
        @data.clear

        duped.inject({}) do |acc, (name, key, type)|
          acc[name] ||= {}
          acc[name][key] = type
          acc
        end
      end

      # Drain accumulated shapes into a single telemetry event payload,
      # matching api-telemetry's ContextShapesSchema. Returns +nil+ when
      # there is nothing to ship — the reporter should skip empty events.
      def drain_event
        return nil if @data.size.zero?

        shapes = prepare_data.map do |name, field_types|
          { 'name' => name, 'fieldTypes' => field_types }
        end

        { 'contextShapes' => { 'shapes' => shapes } }
      end

      private

      def each_named_context(context)
        if context.respond_to?(:contexts)
          # Quonfig::Context — each_pair yields (name, NamedContext)
          context.contexts.each_pair do |name, named|
            yield name, (named.respond_to?(:to_h) ? named.to_h : named)
          end
        elsif context.is_a?(Hash)
          context.each_pair do |name, values|
            values = { name.to_s => values } unless values.is_a?(Hash)
            yield name, values
          end
        end
      end
    end
  end
end
