# frozen_string_literal: true

require 'test_helper'

# Tier 1 supervisor unit-test contract (qfg-47c2.9 / qfg-47c2.2).
# Source: integration-test-data/chaos/supervisor-test-contract.md
#
# Tests 1-4 from the contract. Tests 5 (callback panic) and 6
# (connectionState / lastSuccessfulRefresh) are tracked separately on
# qfg-47c2.16 — they need surface area this bead does not introduce.
class TestWorkerSupervisor < Minitest::Test
  # ------------------------------------------------------------------
  # Test 1 — Restart on worker throw within 1000ms
  # ------------------------------------------------------------------
  def test_supervisor_restarts_worker_within_1000ms
    queue = Queue.new
    calls = Concurrent::AtomicFixnum.new(0)

    worker = lambda do |_envelope_delivered|
      n = calls.increment
      queue << n
      raise StandardError, 'simulated worker throw' if n == 1

      # Second call: block forever simulating a healthy long-lived connection.
      sleep 30
    end

    supervisor = Quonfig::WorkerSupervisor.new(
      name: 'sse', layer: '1', worker: worker,
      sleep_proc: ->(_s) {}, # collapse backoff sleeps in tests
      logger: Logger.new(StringIO.new)
    )
    supervisor.start

    begin
      first = queue.pop(timeout: 1.0)
      second = queue.pop(timeout: 1.0)

      assert_equal 1, first
      assert_equal 2, second
      assert supervisor.alive?, 'supervisor itself must still be alive after worker throw'
    ensure
      supervisor.stop
    end
  end

  # ------------------------------------------------------------------
  # Test 2 — Exponential backoff to 30s cap
  # ------------------------------------------------------------------
  def test_supervisor_backoff_sequence_caps_at_30s
    requested = Concurrent::Array.new
    done = Concurrent::Event.new
    attempts = Concurrent::AtomicFixnum.new(0)

    worker = lambda do |_d|
      attempts.increment
      raise StandardError, 'always fails'
    end

    # Always-fail worker, with a sleep_proc that records the requested backoff
    # and signals after 8 cycles so the test wakes up in <1s wall-clock.
    sleep_proc = lambda do |seconds|
      requested << seconds
      done.set if requested.size >= 8
    end

    supervisor = Quonfig::WorkerSupervisor.new(
      name: 'sse', layer: '1', worker: worker,
      sleep_proc: sleep_proc,
      logger: Logger.new(StringIO.new)
    )
    supervisor.start

    begin
      assert done.wait(2.0), 'supervisor did not produce 8 backoff cycles in 2s'
      first_eight = requested.first(8)
      assert_equal [0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0], first_eight
    ensure
      supervisor.stop
    end
  end

  def test_supervisor_backoff_resets_after_successful_run
    requested = Concurrent::Array.new
    barrier = Queue.new
    attempts = Concurrent::AtomicFixnum.new(0)

    # Worker #1: fail. Worker #2: deliver an envelope then exit cleanly.
    # Worker #3: fail (we want to observe its backoff value).
    worker = lambda do |envelope_delivered|
      n = attempts.increment
      case n
      when 1
        raise StandardError, 'first fail'
      when 2
        envelope_delivered.call
        # exit cleanly
      else
        barrier << n
        raise StandardError, "fail ##{n}"
      end
    end

    sleep_proc = ->(s) { requested << s }

    supervisor = Quonfig::WorkerSupervisor.new(
      name: 'sse', layer: '1', worker: worker,
      sleep_proc: sleep_proc,
      logger: Logger.new(StringIO.new)
    )
    supervisor.start

    begin
      # Wait for worker #3 to be invoked, then look at the backoff queued
      # *between* worker #2 (success) and worker #3 (fail).
      barrier.pop(timeout: 2.0)

      # requested[0] precedes worker #2 (after worker #1 failed): 0.5
      # requested[1] precedes worker #3 (after worker #2 succeeded): 0.5 again
      assert_equal 0.5, requested[0], 'first backoff after failure'
      assert_equal 0.5, requested[1], 'backoff must reset to 500ms after a successful run'
    ensure
      supervisor.stop
    end
  end

  # ------------------------------------------------------------------
  # Test 3 — Clean shutdown within 5s
  # ------------------------------------------------------------------
  def test_supervisor_close_joins_worker_within_5s
    started = Queue.new

    worker = lambda do |_d|
      started << :go
      sleep 60 # block forever; supervisor must signal shutdown
      # If we hit here without Shutdown being raised, the supervisor's
      # cooperative-cancel mechanism is broken — fail loudly.
      raise 'worker slept the full 60s; supervisor never signaled shutdown'
    end

    supervisor = Quonfig::WorkerSupervisor.new(
      name: 'sse', layer: '1', worker: worker,
      sleep_proc: ->(_s) {},
      logger: Logger.new(StringIO.new)
    )
    supervisor.start
    started.pop(timeout: 1.0)

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    supervisor.stop
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    assert elapsed < 5.0, "stop() took #{elapsed}s, must be < 5s"
    refute supervisor.alive?, 'supervisor thread must be joined after stop'

    # Idempotent
    supervisor.stop
  end

  # ------------------------------------------------------------------
  # Test 4 — worker_restart_total counter
  # ------------------------------------------------------------------
  def test_worker_restart_total_increments_per_restart
    sup_logger = Logger.new(StringIO.new)
    restart_event = Concurrent::Event.new
    attempts = Concurrent::AtomicFixnum.new(0)

    worker = lambda do |_d|
      n = attempts.increment
      raise StandardError, "fail ##{n}" if n <= 3

      restart_event.set
      sleep 30
    end

    supervisor = Quonfig::WorkerSupervisor.new(
      name: 'sse', layer: '1', worker: worker,
      sleep_proc: ->(_s) {},
      logger: sup_logger
    )

    assert_equal 0, supervisor.worker_restart_total
    supervisor.start

    begin
      assert restart_event.wait(2.0), 'supervisor never reached the healthy worker'
      assert_equal 3, supervisor.worker_restart_total
      assert_equal({ sdk: 'ruby', sdk_version: Quonfig::VERSION, layer: '1' },
                   supervisor.worker_restart_labels)
    ensure
      supervisor.stop
    end
  end

  def test_metric_name_matches_contract
    # The Tier 1 supervisor-test-contract names the counter
    # quonfig_sdk_worker_restart_total. Other SDKs use that exact string;
    # keep parity so a future shared scraper can read it.
    assert_equal 'quonfig_sdk_worker_restart_total',
                 Quonfig::WorkerSupervisor::METRIC_NAME
  end
end
