# frozen_string_literal: true

module Quonfig
  # In-memory store of configs keyed by config key.
  #
  # Integration tests and the Resolver/Evaluator trio construct this
  # directly, independent of any Client/ConfigLoader plumbing.
  #
  # Thread-safety (qfg-i86q): the store holds one frozen Hash snapshot behind
  # an AtomicReference. An install builds the next Hash off to the side and
  # swaps the reference once (#replace_all), so a reader sees the old
  # envelope or the new one, never a mix. Matches sdk-go runtime_store.go.
  # #set / #delete / #clear are copy-on-write under a writer mutex, for the
  # test harness and single-key callers.
  #
  # One lookup can read several keys (a flag, then the segments it
  # references, then a decryptWith key). #pinned holds one snapshot for the
  # current thread for the duration of a block, so every read in that
  # lookup comes from the same envelope even if an install swaps the store
  # mid-evaluation.
  class ConfigStore
    EMPTY = {}.freeze
    private_constant :EMPTY

    def initialize(initial_configs = nil)
      @write_mutex = Mutex.new
      @pin_key = :"__quonfig_store_pin_#{object_id}"
      @snapshot = Concurrent::AtomicReference.new(EMPTY)
      return unless initial_configs

      replace_all(initial_configs.to_h)
    end

    def get(key)
      snapshot[key]
    end

    def set(key, config)
      @write_mutex.synchronize do
        @snapshot.set(@snapshot.get.merge(key => config).freeze)
      end
      config
    end

    def delete(key)
      @write_mutex.synchronize do
        current = @snapshot.get
        return nil unless current.key?(key)

        next_map = current.dup
        value = next_map.delete(key)
        @snapshot.set(next_map.freeze)
        value
      end
    end

    def clear
      replace_all(EMPTY)
    end

    # Atomically replace every config with +configs+ (a Hash of key =>
    # config). Readers see either the previous set or this one.
    def replace_all(configs)
      next_map = configs.frozen? ? configs : configs.dup.freeze
      @write_mutex.synchronize { @snapshot.set(next_map) }
      nil
    end

    def keys
      snapshot.keys
    end

    def all_configs
      snapshot.dup
    end

    # Run the block with this thread's reads pinned to the current snapshot.
    # Re-entrant: a nested call keeps the outer pin.
    def pinned
      return yield if Thread.current[@pin_key]

      Thread.current[@pin_key] = @snapshot.get
      begin
        yield
      ensure
        Thread.current[@pin_key] = nil
      end
    end

    private

    def snapshot
      Thread.current[@pin_key] || @snapshot.get
    end
  end
end
