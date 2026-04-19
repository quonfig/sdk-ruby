# frozen_string_literal: true

require_relative 'periodic_sync'

module Quonfig
  class ContextShapeAggregator
    include Quonfig::PeriodicSync
    LOG = Quonfig::InternalLogger.new(self)

    attr_reader :data

    def initialize(client:, max_shapes:, sync_interval:)
      @max_shapes = max_shapes
      @client = client
      @name = 'context_shape_aggregator'

      @data = Concurrent::Set.new

      start_periodic_sync(sync_interval)
    end

    def push(context)
      return if @data.size >= @max_shapes

      context.contexts.each_pair do |name, name_context|
        name_context.to_h.each_pair do |key, value|
          @data.add [name, key, Quonfig::ContextShape.field_type_number(value)]
        end
      end
    end

    def prepare_data
      duped = @data.dup
      @data.clear

      duped.inject({}) do |acc, (name, key, type)|
        acc[name] ||= {}
        acc[name][key] = type
        acc
      end
    end

    private

    def flush(to_ship, _)
      pool.post do
        LOG.debug "Uploading context shapes for #{to_ship.values.size}"

        events = PrefabProto::TelemetryEvents.new(
          instance_hash: instance_hash,
          events: [
            PrefabProto::TelemetryEvent.new(context_shapes:
              PrefabProto::ContextShapes.new(
                shapes: to_ship.map do |name, shape|
                  PrefabProto::ContextShape.new(
                    name: name,
                    field_types: shape
                  )
                end
              ))
          ]
        )

        result = post('/api/v1/telemetry', events)

        LOG.debug "Uploaded #{to_ship.values.size} shapes: #{result.status}"
      end
    end
  end
end
