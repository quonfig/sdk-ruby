# frozen_string_literal: true

module Quonfig
  # In-memory store of configs keyed by config key.
  #
  # Mirrors sdk-node's ConfigStore (src/store.ts). Integration tests and the
  # new Resolver/Evaluator trio construct this directly, independent of any
  # Client/ConfigLoader plumbing.
  class ConfigStore
    def initialize(initial_configs = nil)
      @lock = Concurrent::ReadWriteLock.new
      @configs = Concurrent::Map.new
      return unless initial_configs

      initial_configs.each { |k, v| @configs[k] = v }
    end

    def get(key)
      @configs[key]
    end

    def set(key, config)
      @lock.with_write_lock { @configs[key] = config }
    end

    def clear
      @lock.with_write_lock do
        @configs.keys.each { |k| @configs.delete(k) }
      end
    end

    def keys
      @configs.keys
    end

    def all_configs
      h = {}
      @configs.each_pair { |k, v| h[k] = v }
      h
    end
  end
end
