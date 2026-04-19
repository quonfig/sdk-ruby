# frozen_string_literal: true

require_relative 'periodic_sync'

module Quonfig
  # Aggregates observed context shapes (field name → type number) and flushes
  # them as telemetry to POST /api/v1/telemetry/ as a single consolidated JSON
  # body (see api-telemetry TelemetryEventsSchema).
  class ContextShapeAggregator
    include Quonfig::PeriodicSync
    LOG = Quonfig::InternalLogger.new(self)

    TELEMETRY_PATH = '/api/v1/telemetry/'

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

        payload = {
          instanceHash: instance_hash,
          events: [
            {
              contextShapes: {
                shapes: to_ship.map { |name, shape| { name: name, fieldTypes: shape } }
              }
            }
          ]
        }

        result = post(TELEMETRY_PATH, payload)

        LOG.debug "Uploaded #{to_ship.values.size} shapes: #{result.status}"
      end
    end
  end
end
