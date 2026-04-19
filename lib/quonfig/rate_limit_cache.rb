# frozen_string_literal: true

module Quonfig
  # A key-based rate limiter that considers a key to be fresh if it has been
  # seen within the last `duration` seconds.
  #
  # This is used to rate limit the number of times we send a given context
  # to the server.
  #
  # Because expected usage is to immediately `set` on a `fresh?` miss, we do
  # not prune the data structure on `fresh?` calls. Instead, we manually invoke
  # `prune` periodically from the cache consumer.
  class RateLimitCache
    attr_reader :data

    def initialize(duration)
      @data = Concurrent::Map.new
      @duration = duration
    end

    def fresh?(key)
      timestamp = @data[key]

      return false unless timestamp
      return false if Time.now.utc.to_i - timestamp > @duration

      true
    end

    def set(key)
      @data[key] = Time.now.utc.to_i
    end

    def prune
      now = Time.now.utc.to_i
      @data.each_pair do |key, (timestamp, _)|
        @data.delete(key) if now - timestamp > @duration
      end
    end
  end
end
