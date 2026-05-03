# frozen_string_literal: true

require 'test_helper'

# Thread-safety and fork-mode coverage for ConfigStore + Client.
#
# These tests guard the property that ConfigStore reads can run concurrently
# with writers (mimicking SSE envelope application) without raising,
# deadlocking, or returning torn state — and that Client#fork produces a
# usable, independent client when called from a forked Ruby process.
class TestThreadSafety < Minitest::Test
  def test_config_store_concurrent_reads_during_writes
    store = Quonfig::ConfigStore.new
    seed_keys = (0...20).map { |i| "seed.#{i}" }
    seed_keys.each { |k| store.set(k, { 'key' => k, 'value' => 0 }) }

    stop = Concurrent::AtomicBoolean.new(false)
    errors = Concurrent::Array.new

    readers = Array.new(8) do
      Thread.new do
        Thread.current.report_on_exception = false
        until stop.true?
          seed_keys.each do |k|
            cfg = store.get(k)
            next if cfg.nil?
            unless cfg.is_a?(Hash) && cfg['key'] == k
              errors << "torn read for #{k}: #{cfg.inspect}"
            end
          end
        end
      rescue StandardError => e
        errors << "reader: #{e.class}: #{e.message}"
      end
    end

    writers = Array.new(2) do |w|
      Thread.new do
        Thread.current.report_on_exception = false
        500.times do |i|
          k = seed_keys[i % seed_keys.length]
          store.set(k, { 'key' => k, 'value' => (w * 1000) + i })
        end
        # Simulate an SSE envelope: drop a key then re-add it.
        20.times do |i|
          k = "ephemeral.#{w}.#{i}"
          store.set(k, { 'key' => k, 'value' => i })
          store.delete(k)
        end
      rescue StandardError => e
        errors << "writer: #{e.class}: #{e.message}"
      end
    end

    writers.each(&:join)
    stop.make_true
    readers.each { |t| t.join(5) || raise("reader thread did not exit — possible deadlock") }

    assert_empty errors, "concurrent ops produced errors: #{errors.to_a.first(5).inspect}"
    seed_keys.each { |k| refute_nil store.get(k), "seed key #{k} disappeared" }
  end

  def test_config_store_clear_does_not_raise_under_concurrent_reads
    store = Quonfig::ConfigStore.new
    50.times { |i| store.set("k.#{i}", { 'key' => "k.#{i}" }) }

    stop = Concurrent::AtomicBoolean.new(false)
    errors = Concurrent::Array.new

    reader = Thread.new do
      Thread.current.report_on_exception = false
      until stop.true?
        store.keys.each { |k| store.get(k) }
      end
    rescue StandardError => e
      errors << e
    end

    20.times do
      50.times { |i| store.set("k.#{i}", { 'key' => "k.#{i}" }) }
      store.clear
    end

    stop.make_true
    reader.join(5) || raise("reader did not exit — possible deadlock")
    assert_empty errors
  end

  # Client#fork builds a fresh client with `is_fork = true` propagated through
  # Options#for_fork. Verify the new client is a distinct instance with its
  # own store, and the parent's store is unaffected.
  #
  # We exercise the in-process fork-equivalent (Client#fork) rather than
  # Process.fork so the test runs in CI without daemonizing — Process.fork
  # would orphan the SSE thread on the child side and complicate the assert.
  def test_client_fork_returns_independent_client_with_own_store
    parent_store = Quonfig::ConfigStore.new
    parent_store.set('shared.key', { 'key' => 'shared.key', 'value' => 'parent' })

    # `on_init_failure: :return` so the fork's network init logs+returns
    # instead of raising — we don't have a real api-delivery in unit tests.
    parent = Quonfig::Client.new(
      Quonfig::Options.new(
        sdk_key: '1-test-key',
        api_urls: ['http://127.0.0.1:1/never-listens'],
        enable_sse: false,
        enable_polling: false,
        initialization_timeout_sec: 1,
        on_init_failure: :return
      ),
      store: parent_store
    )

    child = parent.fork
    refute_same parent, child
    refute_same parent.store, child.store, "fork must allocate a fresh ConfigStore"

    child.store.set('child.only', { 'key' => 'child.only' })
    assert_nil parent.store.get('child.only'), "parent must not see child writes"
    assert child.options.is_fork, "forked Options must carry is_fork = true"

    # The fork hits a non-listening port and logs a warn under
    # on_init_failure: :return — acknowledge it so common_helpers teardown
    # doesn't flag it as unexpected.
    assert_logged([/Initialization did not complete cleanly/])
  ensure
    parent&.stop
    child&.stop
  end
end
