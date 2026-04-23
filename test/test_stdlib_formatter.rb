# frozen_string_literal: true

require 'test_helper'
require 'logger'
require 'stringio'

# Verifies Quonfig::StdlibFormatter — an adapter that plugs Quonfig's dynamic
# log-level evaluation into Ruby's built-in ::Logger via the
# `logger.formatter = <proc>` contract. The formatter is a callable with
# signature (severity, datetime, progname, msg) -> String. Returning an empty
# string suppresses the log line (Logger writes exactly what the formatter
# returns).
#
# The Ruby stdlib severity strings ("DEBUG", "INFO", "WARN", "ERROR", "FATAL",
# "ANY") are mapped to the quonfig level symbols used by the evaluator
# (:debug, :info, :warn, :error, :fatal). progname flows into the evaluator
# under `quonfig-sdk-logging.key` verbatim, no normalization — matching the
# SemanticLoggerFilter.
class TestStdlibFormatter < Minitest::Test
  LOG_LEVEL_KEY = 'log-level.my-app'

  # Build a minimal config fixture: a string config whose single rule always
  # resolves to `level`. Mirrors the shape used in test_should_log.rb so we
  # exercise the full get()/resolver/evaluator path rather than stubbing.
  def make_log_level_config(key:, level:)
    {
      'id' => '1',
      'key' => key,
      'type' => 'config',
      'valueType' => 'string',
      'sendToClientSdk' => false,
      'default' => {
        'rules' => [
          { 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
            'value' => { 'type' => 'string', 'value' => level } }
        ]
      },
      'environment' => nil
    }
  end

  def store_with(*configs)
    store = Quonfig::ConfigStore.new
    configs.each { |c| store.set(c['key'], c) }
    store
  end

  def client_with(store, **options)
    Quonfig::Client.new(Quonfig::Options.new(**options), store: store)
  end

  # ---- error behavior --------------------------------------------------

  def test_stdlib_formatter_raises_without_logger_key
    client = client_with(Quonfig::ConfigStore.new)
    err = assert_raises(Quonfig::Error) { client.stdlib_formatter }
    assert_match(/logger_key/, err.message)
  end

  # ---- proc contract ---------------------------------------------------

  def test_stdlib_formatter_returns_a_callable_with_4_arity
    store = store_with(make_log_level_config(key: LOG_LEVEL_KEY, level: 'info'))
    client = client_with(store, logger_key: LOG_LEVEL_KEY)

    formatter = client.stdlib_formatter
    assert_respond_to formatter, :call
    # Ruby Logger invokes formatter with exactly 4 args; a Proc takes any arity,
    # but arity should be 4 so it matches the Logger contract faithfully.
    assert_equal 4, formatter.arity
  end

  # ---- gating ----------------------------------------------------------

  def test_formatter_drops_below_configured_level_returning_empty_string
    store = store_with(make_log_level_config(key: LOG_LEVEL_KEY, level: 'warn'))
    client = client_with(store, logger_key: LOG_LEVEL_KEY)

    formatter = client.stdlib_formatter
    now = Time.utc(2026, 4, 22, 12, 0, 0)

    # Below configured warn — suppressed (empty string, which Logger writes
    # as zero bytes, effectively dropping the line).
    assert_equal '', formatter.call('DEBUG', now, 'MyApp::Foo', 'hi')
    assert_equal '', formatter.call('INFO',  now, 'MyApp::Foo', 'hi')
  end

  def test_formatter_emits_at_or_above_configured_level
    store = store_with(make_log_level_config(key: LOG_LEVEL_KEY, level: 'warn'))
    client = client_with(store, logger_key: LOG_LEVEL_KEY)

    formatter = client.stdlib_formatter
    now = Time.utc(2026, 4, 22, 12, 0, 0)

    refute_equal '', formatter.call('WARN',  now, 'MyApp::Foo', 'hi')
    refute_equal '', formatter.call('ERROR', now, 'MyApp::Foo', 'hi')
    refute_equal '', formatter.call('FATAL', now, 'MyApp::Foo', 'hi')
  end

  def test_formatter_default_format_includes_severity_time_progname_msg
    store = store_with(make_log_level_config(key: LOG_LEVEL_KEY, level: 'debug'))
    client = client_with(store, logger_key: LOG_LEVEL_KEY)

    formatter = client.stdlib_formatter
    now = Time.utc(2026, 4, 22, 12, 34, 56)

    out = formatter.call('INFO', now, 'MyApp::Foo', 'hello world')
    assert_includes out, 'INFO'
    assert_includes out, 'MyApp::Foo'
    assert_includes out, 'hello world'
    assert out.end_with?("\n"), "formatter output should end with a newline"
  end

  # ---- progname -> context ---------------------------------------------

  def test_progname_flows_into_logger_context_verbatim
    # We capture the context the formatter passes to should_log? by replacing
    # the client's should_log? — avoids building a matcher fixture and lets
    # us assert the exact context shape the adapter builds.
    store = store_with(make_log_level_config(key: LOG_LEVEL_KEY, level: 'trace'))
    client = client_with(store, logger_key: LOG_LEVEL_KEY)

    captured = []
    client.define_singleton_method(:should_log?) do |logger_path:, desired_level:, contexts: {}|
      captured << { logger_path: logger_path, desired_level: desired_level }
      true
    end

    formatter = client.stdlib_formatter
    formatter.call('INFO', Time.now, 'HTMLParser', 'x')

    assert_equal 1, captured.size
    assert_equal 'HTMLParser', captured.first[:logger_path]
    assert_equal :info,        captured.first[:desired_level]
  end

  def test_explicit_logger_name_option_overrides_progname
    store = store_with(make_log_level_config(key: LOG_LEVEL_KEY, level: 'trace'))
    client = client_with(store, logger_key: LOG_LEVEL_KEY)

    captured = []
    client.define_singleton_method(:should_log?) do |logger_path:, desired_level:, contexts: {}|
      captured << logger_path
      true
    end

    formatter = client.stdlib_formatter(logger_name: 'ExplicitName')
    # Pass a different progname — the explicit logger_name should win.
    formatter.call('INFO', Time.now, 'DifferentProgname', 'x')

    assert_equal 'ExplicitName', captured.first
  end

  def test_nil_progname_and_no_logger_name_falls_through_as_nil
    # Ruby's Logger can invoke the formatter with a nil progname; the adapter
    # should not crash. We pass through nil, and should_log? sees nil. The
    # evaluator treats missing context values as absent.
    store = store_with(make_log_level_config(key: LOG_LEVEL_KEY, level: 'trace'))
    client = client_with(store, logger_key: LOG_LEVEL_KEY)

    captured = []
    client.define_singleton_method(:should_log?) do |logger_path:, desired_level:, contexts: {}|
      captured << logger_path
      true
    end

    formatter = client.stdlib_formatter
    formatter.call('INFO', Time.now, nil, 'x')

    assert_nil captured.first
  end

  # ---- end-to-end with a real ::Logger ---------------------------------

  def test_end_to_end_real_logger_drops_below_and_emits_above
    store = store_with(make_log_level_config(key: LOG_LEVEL_KEY, level: 'warn'))
    client = client_with(store, logger_key: LOG_LEVEL_KEY)

    io = StringIO.new
    logger = ::Logger.new(io)
    # stdlib Logger has its own static level; set it permissive so our
    # formatter is the thing actually gating output.
    logger.level = ::Logger::DEBUG
    logger.formatter = client.stdlib_formatter(logger_name: 'MyApp::Svc')

    logger.info  'should be dropped'
    logger.warn  'should be emitted'
    logger.error 'also emitted'

    out = io.string
    refute_includes out, 'should be dropped'
    assert_includes out, 'should be emitted'
    assert_includes out, 'also emitted'
  end
end
