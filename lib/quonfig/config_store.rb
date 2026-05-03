# frozen_string_literal: true

module Quonfig
  # In-memory store of configs keyed by config key.
  #
  # Mirrors sdk-node's ConfigStore (src/store.ts). Integration tests and the
  # new Resolver/Evaluator trio construct this directly, independent of any
  # Client/ConfigLoader plumbing.
  #
  # Thread-safety: backed by Concurrent::Map, whose per-key reads, writes, and
  # deletes are atomic. There is no compound multi-key operation here that
  # needs an outer lock — envelope application in ConfigLoader is a sequence
  # of independent set/delete calls, and readers tolerate seeing the
  # in-progress mix. Eventual consistency across an envelope is acceptable
  # and matches sdk-node behavior.
  class ConfigStore
    def initialize(initial_configs = nil)
      @configs = Concurrent::Map.new
      return unless initial_configs

      initial_configs.each { |k, v| @configs[k] = v }
    end

    def get(key)
      @configs[key]
    end

    def set(key, config)
      @configs[key] = config
    end

    def delete(key)
      @configs.delete(key)
    end

    def clear
      @configs.keys.each { |k| @configs.delete(k) }
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
