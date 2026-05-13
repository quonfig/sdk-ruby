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
end
