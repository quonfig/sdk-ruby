# frozen_string_literal: true

require 'test_helper'

# qfg-47c2.30 — on_update user callback that raises must be caught by the
# SDK and logged at ERROR with a message mentioning the callback. Chaos
# scenario 10 asserts client.sdkLog('error', /callback|onConfigUpdate/i) >= 1
# so the level (ERROR) and the message text (must include "callback" or
# "onConfigUpdate") are both load-bearing.
class TestOnUpdateCallbackRecovery < Minitest::Test
  class FakeLogger
    attr_reader :messages

    def initialize
      @messages = Hash.new { |h, k| h[k] = [] }
    end

    def debug(msg = nil) = @messages[:debug] << msg
    def info(msg = nil) = @messages[:info] << msg
    def warn(msg = nil) = @messages[:warn] << msg
    def error(msg = nil) = @messages[:error] << msg
  end

  def teardown
    Quonfig::InternalLogger.user_logger = nil if Quonfig::InternalLogger.respond_to?(:user_logger=)
    super
  end

  def build_client(logger)
    Quonfig::Client.new(
      Quonfig::Options.new(logger: logger),
      store: Quonfig::ConfigStore.new
    )
  end

  def test_on_update_raise_is_logged_at_error_with_callback_message
    fake = FakeLogger.new
    client = build_client(fake)
    client.on_update { raise 'simulated user-callback throw for chaos scenario 10' }

    # Notify path is private; we exercise the same helper the SSE and poll
    # paths call so the test pins the exact mechanism: a user callback that
    # raises must be caught HERE, not propagate to the worker loop.
    client.send(:notify_on_update_callback)

    error_lines = fake.messages[:error].compact.join("\n")
    assert_match(/callback|onConfigUpdate/i, error_lines,
                 "expected an ERROR log mentioning the callback; got error=#{fake.messages[:error].inspect} warn=#{fake.messages[:warn].inspect}")
    assert_match(/simulated user-callback throw/, error_lines,
                 'expected the raised exception message to appear in the log')
    refute_match(/Error applying SSE envelope/i, error_lines,
                 'user-callback errors must NOT reuse the apply-envelope log message')
  end

  def test_on_update_success_does_not_log_any_error
    fake = FakeLogger.new
    client = build_client(fake)
    called = false
    client.on_update { called = true }

    client.send(:notify_on_update_callback)

    assert called, 'on_update block must be invoked'
    assert_empty fake.messages[:error]
  end

  def test_notify_with_no_callback_installed_is_a_noop
    fake = FakeLogger.new
    client = build_client(fake)

    client.send(:notify_on_update_callback)

    assert_empty fake.messages[:error]
    assert_empty fake.messages[:warn]
  end

  # Supervisor contract Test 5 (qfg-6vno.6.1, ITD v2026.10.22.2): a caught
  # callback raise counts in quonfig_sdk_callback_errors_total{callback} and is
  # NOT a worker restart.
  def test_on_update_raise_counts_in_callback_errors_total_not_worker_restart_total
    client = build_client(FakeLogger.new)
    calls = 0
    client.on_update do
      calls += 1
      raise 'first call throws' if calls == 1
    end

    assert_equal 0, client.callback_errors_total(callback: 'on_config_update')
    restarts_before = [client.worker_restart_total(layer: '1'), client.worker_restart_total(layer: '2')]

    client.send(:notify_on_update_callback)
    client.send(:notify_on_update_callback)

    assert_equal 2, calls, 'the callback must run again after its raise'
    assert_equal 1, client.callback_errors_total(callback: 'on_config_update')
    assert_equal 1, client.callback_errors_total(callback: :on_config_update)
    assert_equal 0, client.callback_errors_total(callback: 'on_connection_state_change')
    assert_equal 1, client.callback_errors_total
    assert_equal restarts_before,
                 [client.worker_restart_total(layer: '1'), client.worker_restart_total(layer: '2')],
                 'a callback raise is not a worker restart'
  end

  def test_callback_errors_total_rejects_an_unknown_callback_name
    client = build_client(FakeLogger.new)
    assert_raises(ArgumentError) { client.callback_errors_total(callback: 'on_typo') }
  end

  def test_on_update_raise_error_log_includes_the_backtrace
    fake = FakeLogger.new
    client = build_client(fake)
    client.on_update { raise 'boom with a stack' }

    client.send(:notify_on_update_callback)

    error_lines = fake.messages[:error].compact.join("\n")
    assert_match(/boom with a stack/, error_lines)
    assert_includes error_lines, File.basename(__FILE__), "the ERROR log must carry the stack: #{error_lines}"
  end
end
