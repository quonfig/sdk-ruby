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

  # ------------------------------------------------------------------
  # Layer 2 fallback poller — engage/disengage on SSE state edges
  # (qfg-47c2.26). Mirrors sdk-python `_handle_sse_state_change` in
  # quonfig/client.py.
  # ------------------------------------------------------------------

  # The fallback worker calls @config_loader.fetch! after each sleep. Tests
  # never want a real fetch — install a no-op double so the supervisor stays
  # alive without raising.
  def stub_config_loader!(client)
    fake = Object.new
    def fake.fetch! = nil
    client.instance_variable_set(:@config_loader, fake)
  end

  def test_fallback_engages_immediately_on_initial_sse_error
    # No prior :connected — the SDK never reached SSE, so the fallback
    # engages now (initial-fail path, same as initialize_network_mode's
    # explicit start_polling when start_sse returns false).
    client = make_client(poll_interval: 60)
    stub_config_loader!(client)

    client.send(:handle_sse_state_change, :error)

    assert_equal :falling_back, client.connection_state,
                 'initial :error must engage Layer 2 immediately'
  ensure
    client&.stop
  end

  def test_fallback_engages_after_grace_on_post_connect_sse_error
    # Connected -> error edge schedules a 2*poll_interval grace timer. The
    # supervisor must NOT be alive immediately after the edge, but must
    # become alive once the grace elapses. Use a tiny poll_interval so the
    # test waits ~0.1s, not 120s.
    client = make_client(poll_interval: 0.05)
    stub_config_loader!(client)

    client.send(:handle_sse_state_change, :connected)
    client.send(:handle_sse_state_change, :error)

    # Immediately after error — grace timer pending, fallback not active.
    assert_equal :disconnected, client.connection_state,
                 'must NOT engage immediately on post-connect :error'

    sleep 0.3 # > 2*poll_interval (0.1s)

    assert_equal :falling_back, client.connection_state,
                 'grace elapsed: Layer 2 must engage'
  ensure
    client&.stop
  end

  def test_fallback_disengages_on_sse_recovery
    # Once the fallback poller is active, a recovered SSE :connected edge
    # MUST stop the supervisor — otherwise the SDK would keep two update
    # channels live.
    client = make_client(poll_interval: 0.05)
    stub_config_loader!(client)

    client.send(:handle_sse_state_change, :connected)
    client.send(:handle_sse_state_change, :error)
    sleep 0.3 # let grace fire
    assert_equal :falling_back, client.connection_state

    client.send(:handle_sse_state_change, :connected)

    # Disengagement is synchronous (we call supervisor.stop in-line).
    assert_equal :connected, client.connection_state,
                 'recovery edge must disengage the fallback poller'
    assert_nil client.instance_variable_get(:@poll_supervisor),
               'poll_supervisor reference must be cleared after disengage'
  ensure
    client&.stop
  end

  def test_pending_grace_timer_canceled_on_sse_recovery
    # SSE recovers before the grace timer fires — fallback must never
    # engage at all.
    client = make_client(poll_interval: 0.1)
    stub_config_loader!(client)

    client.send(:handle_sse_state_change, :connected)
    client.send(:handle_sse_state_change, :error)
    # Recovery within the grace window (2*0.1 = 0.2s).
    sleep 0.05
    client.send(:handle_sse_state_change, :connected)

    # Wait past where the original timer would have fired.
    sleep 0.3

    assert_equal :connected, client.connection_state,
                 'canceled grace must not fire after recovery'
    supervisor = client.instance_variable_get(:@poll_supervisor)
    refute supervisor && supervisor.alive?,
           'no supervisor should be alive after canceled-grace recovery'
  ensure
    client&.stop
  end

  # qfg-47c2.27: end-to-end wiring — the SSEConfigClient's on_error path
  # must transition the parent client's @sse_state. Tested by invoking the
  # registered on_error callback the way SSEConfigClient does internally.
  def test_sse_on_error_transitions_connection_state_to_disconnected
    client = make_client(poll_interval: 0)
    # Simulate a successful connect first, then drive an error edge through
    # the wired callback. The bug was: there was no wired callback at all,
    # so connection_state stayed :connected forever after a socket drop.
    client.send(:handle_sse_state_change, :connected)
    assert_equal :connected, client.connection_state

    callback = client.send(:sse_error_callback)
    refute_nil callback, 'client must expose an SSE-error callback for SSEConfigClient'

    callback.call(StandardError.new('socket dropped'))

    assert_equal :disconnected, client.connection_state,
                 'on_error must drive @sse_state to :error so connection_state reports :disconnected'
  ensure
    client&.stop
  end

  def test_fallback_does_not_engage_when_polling_disabled
    client = make_client(poll_interval: 0.05, enable_polling: false)
    stub_config_loader!(client)

    client.send(:handle_sse_state_change, :error)
    sleep 0.2

    assert_equal :disconnected, client.connection_state,
                 'enable_polling=false must keep Layer 2 dormant'
  ensure
    client&.stop
  end

  # qfg-i5xv: a terminal SSE classification (HTTP 401/403/404) MUST NOT engage
  # the Layer 2 fallback poller. The same SDK key that 401'd over SSE will
  # 401 over HTTP polling — engaging polling just moves the auth-failure
  # storm from sse-restart to http-poll. The fallback poller is for transient
  # disruption, not for "the customer's key is bad".
  def test_terminal_sse_error_does_not_engage_polling_fallback
    client = make_client(poll_interval: 0.05)
    stub_config_loader!(client)

    callback = client.send(:sse_error_callback)
    terminal_err = Quonfig::SSEConfigClient::SSEHTTPTerminalError.new(401)
    callback.call(terminal_err)

    # Initial-fail path normally engages polling immediately; with a terminal
    # classification that engagement must be suppressed.
    sleep 0.05
    assert_equal :disconnected, client.connection_state,
                 'terminal SSE error must NOT trigger polling fallback'
    refute client.instance_variable_get(:@poll_supervisor),
           'no Layer 2 supervisor should be alive after terminal SSE error'

    assert client.terminal_failure?,
           'client must expose terminal_failure? to operators after a terminal SSE error'
  ensure
    client&.stop
  end

  def test_terminal_failure_predicate_false_until_terminal_error
    client = make_client(poll_interval: 0.05)
    stub_config_loader!(client)

    refute client.terminal_failure?, 'terminal_failure? must default to false'

    client.send(:handle_sse_state_change, :connected)
    refute client.terminal_failure?, 'terminal_failure? must remain false while connected'

    # Transient (non-terminal) error must NOT flip the predicate.
    callback = client.send(:sse_error_callback)
    callback.call(Quonfig::SSEConfigClient::SSEHTTPStatusError.new(503))
    refute client.terminal_failure?, 'a 503 (transient) must not be classified terminal'
  ensure
    client&.stop
  end
end
