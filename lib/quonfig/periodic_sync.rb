# frozen_string_literal: true

module Quonfig
  module PeriodicSync
    LOG = Quonfig::InternalLogger.new(self)

    def sync
      return if @data.size.zero?

      LOG.debug "Syncing #{@data.size} items"

      start_at_was = @start_at
      @start_at = Quonfig::TimeHelpers.now_in_ms

      flush(prepare_data, start_at_was)
    end

    def prepare_data
      to_ship = @data.dup
      @data.clear

      on_prepare_data

      to_ship
    end

    def on_prepare_data
      # noop -- override as you wish
    end

    def post(url, data)
      @client.post(url, data)
    end

    def instance_hash
      @client.instance_hash
    end

    def start_periodic_sync(sync_interval)
      @start_at = Quonfig::TimeHelpers.now_in_ms

      @sync_interval = calculate_sync_interval(sync_interval)

      Thread.new do
        LOG.debug "Initialized #{@name} instance_hash=#{@client.instance_hash}"

        loop do
          sleep @sync_interval.call
          sync
        end
      end
    end

    def pool
      @pool ||= Concurrent::ThreadPoolExecutor.new(
        fallback_policy: :discard,
        max_queue: 5,
        max_threads: 4,
        min_threads: 1,
        name: @name
      )
    end

    private

    def calculate_sync_interval(sync_interval)
      if sync_interval.is_a?(Numeric)
        proc { sync_interval }
      else
        sync_interval || ExponentialBackoff.new(initial_delay: 8, max_delay: 60 * 5)
      end
    end
  end
end
