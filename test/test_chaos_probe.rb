# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../chaos/probe'
require_relative '../chaos/expressions'

# qfg-goi1.10.35: the default-suite probe's lastSuccessfulRefresh must track
# the SDK accessor (client.last_successful_refresh), which every successful
# poll advances, 304s included. The install-only on_update callback never
# fires on a 304, so a probe stamped from it freezes at the t=0 install and
# chaos 05 exp[2] goes red for a probe reason.
class TestChaosProbe < Minitest::Test
  class FakeClient
    attr_accessor :last_successful_refresh

    def initialize
      @callbacks = []
    end

    def on_update(&blk)
      @callbacks << blk
    end

    def install!(at)
      @last_successful_refresh = at
      @callbacks.each(&:call)
    end

    # A 304 / same-generation poll: freshness advances, no install callback.
    def not_modified!(at)
      @last_successful_refresh = at
    end
  end

  def test_freshness_moves_after_a_304_only_refresh
    client = FakeClient.new
    probe = ChaosProbe.new
    probe.client = client

    client.install!(Time.at(1_700_000_000).utc)
    later = Time.at(1_700_000_100).utc
    client.not_modified!(later)

    assert_equal (later.to_f * 1000).to_i, probe.last_refresh_ms
  end

  def test_freshness_is_zero_before_first_install
    probe = ChaosProbe.new
    assert_equal 0, probe.last_refresh_ms

    probe.client = FakeClient.new
    assert_equal 0, probe.last_refresh_ms
  end

  # 05 exp[3] (after_ms 305000) asserts fallbackPollerActive() == false once
  # SSE is back. The SDK reports :falling_back exactly while its poll
  # supervisor is alive, so the probe reads that, not a latch of its own.
  def test_fallback_clears_when_sdk_reports_connected_again
    client = SdkClient.new
    probe = ChaosProbe.new
    probe.client = client

    client.state = :falling_back
    assert eval_expr("client.connectionState() == 'falling_back' AND client.fallbackPollerActive() == true", probe)

    client.state = :connected

    assert eval_expr("client.connectionState() == 'connected' AND client.fallbackPollerActive() == false", probe),
           'fallbackPollerActive stuck after recovery'
  end

  # ---- qfg-6vno.6: every value the harness asserts on comes from the SDK ----

  # A stand-in with the sdk-ruby Client surface the probe reads: the public
  # diagnostics plus the two private liveness helpers (sse_channel_expected?,
  # sse_worker_alive?) that Client#connection_state itself is built from.
  class SdkClient
    attr_accessor :state, :layer1, :layer2, :last_successful_refresh, :sse_expected, :sse_alive,
                  :callback_errors

    def initialize
      @state = :initializing
      @layer1 = 0
      @layer2 = 0
      @sse_expected = true
      @sse_alive = true
      @values = {}
      @callback_errors = { 'on_config_update' => 0, 'on_connection_state_change' => 0 }
    end

    def callback_errors_total(callback: nil)
      callback ? @callback_errors.fetch(callback.to_s) : @callback_errors.values.sum
    end

    def connection_state
      @state
    end

    def worker_restart_total(layer: nil)
      case layer&.to_s
      when '1' then @layer1
      when '2' then @layer2
      else @layer1 + @layer2
      end
    end

    def ready?
      !@last_successful_refresh.nil?
    end

    def set_value(key, value)
      @values[key] = value
    end

    def get_string(key, default: nil)
      @values.fetch(key, default)
    end

    def on_update(&blk)
      @on_update = blk
    end

    private

    def sse_channel_expected?
      @sse_expected
    end

    def sse_worker_alive?
      @sse_alive
    end
  end

  def eval_expr(expr, probe)
    Quonfig::Chaos::Expressions.evaluate(expr, probe).pass?
  end

  # The supervisor contract forbids any connectionState() value outside
  # initializing|connected|disconnected|falling_back. The probe used to map
  # the SDK's :disconnected-after-:connected to an invented 'reconnecting'.
  def test_connection_state_is_the_sdk_value_after_a_drop
    client = SdkClient.new
    probe = ChaosProbe.new
    probe.client = client

    %i[connected disconnected falling_back connected disconnected].each do |sdk_state|
      client.state = sdk_state
      got = probe.snapshot[:conn_state]
      assert_equal sdk_state.to_s, got, "probe reported #{got.inspect} while the SDK said #{sdk_state.inspect}"
      assert_includes %w[initializing connected disconnected falling_back], got
    end
  end

  # Chaos 10 exp[0] asserts worker_restart_total{layer=1} >= 1 after an
  # onConfigUpdate raise. sdk-ruby recovers that raise inline and does not
  # count it; the probe used to bump its own counter off the log line, so the
  # row passed against probe bookkeeping while the SDK counter stayed 0.
  def test_callback_raise_log_line_is_not_a_restart
    client = SdkClient.new
    client.state = :connected
    probe = ChaosProbe.new
    probe.client = client

    probe.log(:error, 'Quonfig::Client -- [quonfig] onConfigUpdate callback raised: RuntimeError: boom')

    refute eval_expr("client.sdkMetric('quonfig_sdk_worker_restart_total', layer='1') >= 1", probe),
           'layer-1 restarts must be the SDK counter (0 here), not a count of log lines'
    assert eval_expr("client.sdkLog('error', /callback|onConfigUpdate/i) >= 1", probe)
  end

  # Chaos 10 exp[0] at ITD v2026.10.22.2 asserts
  # sdkMetric('quonfig_sdk_callback_errors_total', callback='on_config_update')
  # (qfg-6vno.6.1): the probe reads the SDK's own counter.
  def test_callback_errors_metric_is_the_sdk_counter
    client = SdkClient.new
    client.state = :connected
    probe = ChaosProbe.new
    probe.client = client

    refute eval_expr("client.sdkMetric('quonfig_sdk_callback_errors_total', callback='on_config_update') >= 1", probe)
    client.callback_errors['on_config_update'] = 1
    assert eval_expr("client.sdkMetric('quonfig_sdk_callback_errors_total', callback='on_config_update') >= 1", probe)
    assert eval_expr("client.sdkMetric('quonfig_sdk_callback_errors_total', callback='on_connection_state_change') == 0",
                     probe)
    assert eval_expr("client.sdkMetric('quonfig_sdk_callback_errors_total') == 1", probe)
    assert eval_expr("client.sdkMetric('quonfig_sdk_worker_restart_total', layer='1') == 0", probe)
  end

  # Layer 1/2 restarts are the SDK's own per-layer counters, including restarts
  # that happen between state samples (a flap faster than any poll).
  def test_restart_metrics_are_the_sdk_counters
    client = SdkClient.new
    client.state = :connected
    probe = ChaosProbe.new
    probe.client = client

    client.layer1 = 7
    client.layer2 = 2

    assert eval_expr("client.sdkMetric('quonfig_sdk_worker_restart_total', layer='1') == 7", probe)
    assert eval_expr("client.sdkMetric('quonfig_sdk_worker_restart_total', layer='2') == 2", probe)
    assert eval_expr("client.sdkMetric('quonfig_sdk_worker_restart_total') == 9", probe)
  end

  # Chaos 09 guards quonfig_sse_connect_attempts_total < 100 against a busy
  # reconnect loop. The probe used to count connected edges it happened to
  # sample, so a loop that dialed 150 times while rarely reaching connected
  # still read as a handful of attempts. The SDK dials once, then once per
  # SSEConfigClient#restart_total.
  def test_connect_attempts_come_from_the_sdk_dial_counter
    client = SdkClient.new
    probe = ChaosProbe.new
    probe.client = client

    client.state = :connected
    client.layer1 = 150
    client.state = :disconnected

    refute eval_expr("client.sdkMetric('quonfig_sse_connect_attempts_total') < 100", probe),
           'a 151-dial reconnect storm must trip the 09 guard'
    assert eval_expr("client.sdkMetric('quonfig_sse_connect_attempts_total') == 151", probe)

    client.sse_expected = false
    client.layer1 = 0
    assert eval_expr("client.sdkMetric('quonfig_sse_connect_attempts_total') == 0", probe),
           'no SSE channel, no dials'
  end

  # processStillAlive() must notice the SDK's worker dying, not just that the
  # harness process (which is evaluating the expression) is running.
  def test_process_still_alive_reads_the_sdk_worker
    client = SdkClient.new
    client.state = :connected
    probe = ChaosProbe.new
    probe.client = client

    assert eval_expr('client.processStillAlive() == true', probe)

    client.sse_alive = false
    refute eval_expr('client.processStillAlive() == true', probe),
           'a dead SSE worker thread is the ruby analog of a crashed SDK'
  end

  # Init-failure vocabulary (00-boot-both-down-then-restore): initState(),
  # ready(), getString(key, default) and readyEventCount().
  def test_init_failure_vocabulary
    probe = ChaosProbe.new
    probe.init_state = 'pending'

    assert eval_expr("client.initState() == 'pending'", probe)
    assert eval_expr('client.ready() == false', probe), 'no client yet: not ready'
    assert eval_expr("client.getString('k', 'CODE-DEFAULT') == 'CODE-DEFAULT'", probe)
    assert eval_expr("client.connectionState() == 'initializing'", probe), 'no client yet: initializing'

    client = SdkClient.new
    probe.client = client
    probe.init_state = 'returned'
    assert eval_expr("client.initState() == 'returned'", probe)
    assert eval_expr("client.getString('k', 'CODE-DEFAULT') == 'CODE-DEFAULT'", probe)
    refute eval_expr('client.readyEventCount() >= 1', probe)

    client.set_value('k', 'hello from no env row')
    client.last_successful_refresh = Time.now
    probe.note_ready_event
    assert eval_expr(
      "client.ready() == true AND client.readyEventCount() >= 1 AND client.getString('k', 'CODE-DEFAULT') == 'hello from no env row'",
      probe
    )
  end
end
