# frozen_string_literal: true

require 'test_helper'

# Customer-visible health primitives (qfg-47c2.16).
#
# Covers Tier 1 supervisor unit-test 6 from
# `integration-test-data/chaos/supervisor-test-contract.md`:
#
# - `client.last_successful_refresh` -> Time | nil — wall-clock time of the
#   most recent installed envelope.
# - `client.connection_state` -> Symbol — one of :initializing, :connected,
#   :disconnected, :falling_back.
#
# NO `healthy?` primitive is exposed. The plan explicitly forbids a binary
# health signal because customers would wire it into k8s liveness probes
# and amplify transient blips into restart cascades.
class TestHealthPrimitives < Minitest::Test
  def make_client(**options)
    Quonfig::Client.new(Quonfig::Options.new(**options), store: Quonfig::ConfigStore.new)
  end

  # ------------------------------------------------------------------
  # NO healthy? primitive
  # ------------------------------------------------------------------
  def test_no_healthy_method
    client = make_client
    refute client.respond_to?(:healthy?),
           'Client must NOT expose healthy? — see sdk-hardening-and-verification.md Phase 4'
    refute client.respond_to?(:healthy),
           'Client must NOT expose healthy — see sdk-hardening-and-verification.md Phase 4'
  end

  # ------------------------------------------------------------------
  # last_successful_refresh
  # ------------------------------------------------------------------
  def test_last_successful_refresh_is_nil_before_first_install
    client = make_client
    assert_nil client.last_successful_refresh
  end

  def test_last_successful_refresh_stamps_a_time
    client = make_client
    before = Time.now.utc
    client.send(:record_refresh!)
    after = Time.now.utc

    stamp = client.last_successful_refresh
    assert_kind_of Time, stamp
    assert stamp.utc?, 'stamp must be UTC'
    assert stamp.between?(before, after),
           "stamp #{stamp} not within [#{before}, #{after}]"
  end

  def test_last_successful_refresh_advances_on_subsequent_install
    client = make_client
    client.send(:record_refresh!)
    first = client.last_successful_refresh
    sleep 0.01 # monotonic clock advance
    client.send(:record_refresh!)
    second = client.last_successful_refresh

    refute_nil first
    refute_nil second
    assert second > first,
           "second stamp (#{second}) must be after first (#{first})"
  end

  def test_last_successful_refresh_preserved_after_stop
    client = make_client
    client.send(:record_refresh!)
    stamp = client.last_successful_refresh
    refute_nil stamp

    client.stop
    assert_equal stamp, client.last_successful_refresh,
                 'close/stop must NOT zero out the timestamp'
  end

  def test_last_successful_refresh_is_thread_safe
    client = make_client

    threads = Array.new(4) do
      Thread.new do
        100.times { client.send(:record_refresh!) }
      end
    end
    threads.each(&:join)

    refute_nil client.last_successful_refresh
    assert_kind_of Time, client.last_successful_refresh
  end

  # ------------------------------------------------------------------
  # connection_state
  # ------------------------------------------------------------------
  def test_connection_state_returns_initializing_before_first_install
    client = make_client
    assert_equal :initializing, client.connection_state
  end

  def test_connection_state_returns_connected_after_sse_connect
    client = make_client
    client.send(:handle_sse_state_change, :connected)
    assert_equal :connected, client.connection_state
  end

  def test_connection_state_returns_disconnected_after_sse_error_post_connect
    # After a successful connect, an error edge transitions to :disconnected
    # (no fallback poller has engaged in this Ruby SDK because polling is
    # fallback-only at start time, not a post-connect recovery).
    client = make_client
    client.send(:handle_sse_state_change, :connected)
    client.send(:handle_sse_state_change, :error)
    assert_equal :disconnected, client.connection_state
  end

  def test_connection_state_returns_falling_back_when_poller_alive
    client = make_client
    # Simulate fallback engagement by injecting a live poll supervisor.
    fake_supervisor = Object.new
    def fake_supervisor.alive? = true
    def fake_supervisor.worker_restart_total = 0
    def fake_supervisor.stop = nil
    client.instance_variable_set(:@poll_supervisor, fake_supervisor)

    assert_equal :falling_back, client.connection_state
  end

  def test_connection_state_returns_connected_after_sse_recovers
    client = make_client
    client.send(:handle_sse_state_change, :connected)
    client.send(:handle_sse_state_change, :error)
    assert_equal :disconnected, client.connection_state

    client.send(:handle_sse_state_change, :connected)
    assert_equal :connected, client.connection_state
  end

  def test_connection_state_returns_disconnected_after_stop
    client = make_client
    client.send(:handle_sse_state_change, :connected)
    assert_equal :connected, client.connection_state

    client.stop
    assert_equal :disconnected, client.connection_state
  end

  def test_connection_state_returns_connected_in_datadir_mode
    # Datadir mode: no network, but a successful envelope install means the
    # client is delivering configs. State must be :connected, not :initializing.
    # Simulated here by recording a refresh on a test-mode client and asserting
    # that an install (no SSE) reads as :connected.
    client = make_client
    client.send(:record_refresh!)
    # Without an SSE state change, an installed envelope alone reads as
    # :connected — matches the supervisor contract's "after first envelope:
    # connected" line.
    assert_equal :connected, client.connection_state
  end

  # ------------------------------------------------------------------
  # Tier 1 Test 6 — full transition cycle
  # ------------------------------------------------------------------
  def test_connection_state_full_lifecycle
    client = make_client
    log = []

    log << client.connection_state # initializing

    client.send(:handle_sse_state_change, :connecting)
    log << client.connection_state # initializing (no install yet)

    client.send(:handle_sse_state_change, :connected)
    client.send(:record_refresh!)
    log << client.connection_state # connected

    client.send(:handle_sse_state_change, :error)
    log << client.connection_state # disconnected (no fallback engaged here)

    client.send(:handle_sse_state_change, :connected)
    log << client.connection_state # connected (recovery)

    client.stop
    log << client.connection_state # disconnected

    assert_equal :initializing, log[0]
    assert_equal :initializing, log[1]
    assert_equal :connected, log[2]
    assert_equal :disconnected, log[3]
    assert_equal :connected, log[4]
    assert_equal :disconnected, log[5]

    # Every state in the documented set must appear in the log.
    seen = log.uniq
    assert_includes seen, :initializing
    assert_includes seen, :connected
    assert_includes seen, :disconnected
    # :falling_back is exercised by test_connection_state_returns_falling_back_when_poller_alive
  end

  def test_connection_state_only_returns_documented_values
    documented = %i[initializing connected disconnected falling_back]
    client = make_client

    [
      -> { client.connection_state }, # initializing
      lambda {
        client.send(:handle_sse_state_change, :connected)
        client.connection_state
      },
      lambda {
        client.send(:handle_sse_state_change, :error)
        client.connection_state
      },
      lambda {
        client.stop
        client.connection_state
      }
    ].each do |probe|
      state = probe.call
      assert_includes documented, state,
                      "connection_state returned #{state.inspect}, not in #{documented}"
    end
  end
end
