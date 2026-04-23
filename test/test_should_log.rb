# frozen_string_literal: true

require 'test_helper'

# Verifies the client-level should_log?(logger_path:, desired_level:, contexts:)
# API — a Reforge-style convenience built on top of the primitive get() that
# uses the client's `logger_key` option as the config key and injects the
# logger path under `quonfig-sdk-logging.key`. Parallels sdk-node's
# shouldLog({loggerPath}) and sdk-go's ShouldLogPath.
class TestShouldLog < Minitest::Test
  LOG_LEVEL_KEY = 'log-level.my-app'

  # Minimal config fixture mirroring what ConfigStore expects: a string
  # config whose rule returns the configured log level.
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

  # ---- logger_key option surface ---------------------------------------

  def test_logger_key_option_defaults_to_nil
    assert_nil Quonfig::Options.new.logger_key
  end

  def test_logger_key_option_accepts_value
    opts = Quonfig::Options.new(logger_key: LOG_LEVEL_KEY)
    assert_equal LOG_LEVEL_KEY, opts.logger_key
  end

  def test_client_exposes_logger_key_from_options
    client = client_with(Quonfig::ConfigStore.new, logger_key: LOG_LEVEL_KEY)
    assert_equal LOG_LEVEL_KEY, client.logger_key
  end

  # ---- should_log? requires logger_key ---------------------------------

  def test_should_log_raises_without_logger_key
    client = client_with(Quonfig::ConfigStore.new)
    err = assert_raises(Quonfig::Error) do
      client.should_log?(logger_path: 'MyApp::Foo', desired_level: :info)
    end
    assert_match(/logger_key/, err.message)
  end

  # ---- should_log? gating ----------------------------------------------

  def test_should_log_true_when_desired_at_or_above_configured
    store = store_with(make_log_level_config(key: LOG_LEVEL_KEY, level: 'info'))
    client = client_with(store, logger_key: LOG_LEVEL_KEY)

    assert_equal true, client.should_log?(logger_path: 'MyApp::Foo', desired_level: :info)
    assert_equal true, client.should_log?(logger_path: 'MyApp::Foo', desired_level: :warn)
    assert_equal true, client.should_log?(logger_path: 'MyApp::Foo', desired_level: :error)
    assert_equal true, client.should_log?(logger_path: 'MyApp::Foo', desired_level: :fatal)
  end

  def test_should_log_false_when_desired_below_configured
    store = store_with(make_log_level_config(key: LOG_LEVEL_KEY, level: 'warn'))
    client = client_with(store, logger_key: LOG_LEVEL_KEY)

    assert_equal false, client.should_log?(logger_path: 'MyApp::Foo', desired_level: :trace)
    assert_equal false, client.should_log?(logger_path: 'MyApp::Foo', desired_level: :debug)
    assert_equal false, client.should_log?(logger_path: 'MyApp::Foo', desired_level: :info)
    assert_equal true,  client.should_log?(logger_path: 'MyApp::Foo', desired_level: :warn)
  end

  def test_should_log_accepts_string_desired_level
    store = store_with(make_log_level_config(key: LOG_LEVEL_KEY, level: 'warn'))
    client = client_with(store, logger_key: LOG_LEVEL_KEY)

    assert_equal true,  client.should_log?(logger_path: 'MyApp::Foo', desired_level: 'warn')
    assert_equal false, client.should_log?(logger_path: 'MyApp::Foo', desired_level: 'info')
  end

  def test_should_log_returns_true_when_no_config_found
    # Missing config key → log everything (match go/node).
    client = client_with(Quonfig::ConfigStore.new, logger_key: LOG_LEVEL_KEY)
    assert_equal true, client.should_log?(logger_path: 'MyApp::Foo', desired_level: :trace)
  end

  # ---- context injection -----------------------------------------------

  # Capture what context reaches get() by injecting a spy client that wraps
  # a real store-backed client.
  class ContextCapturingClient
    attr_reader :captured_contexts

    def initialize(delegate)
      @delegate = delegate
      @captured_contexts = []
    end

    def logger_key
      @delegate.logger_key
    end

    def get(key, default = Quonfig::NO_DEFAULT_PROVIDED, jit_context = Quonfig::NO_DEFAULT_PROVIDED)
      @captured_contexts << jit_context
      @delegate.get(key, default, jit_context)
    end
  end

  def test_should_log_injects_logger_path_under_quonfig_sdk_logging_key
    store = store_with(make_log_level_config(key: LOG_LEVEL_KEY, level: 'trace'))
    client = client_with(store, logger_key: LOG_LEVEL_KEY)

    # Reach into the context that get() sees. We do this by asserting on the
    # resolver via a fake — simplest path: call should_log? with a sentinel
    # path and verify the evaluator would see it. We assert via the public
    # contract: context reaches get(), so we patch get() temporarily.
    captured = []
    client.define_singleton_method(:get) do |key, default = nil, jit_context = nil|
      captured << { key: key, jit_context: jit_context }
      'trace'
    end

    client.should_log?(logger_path: 'MyApp::Services::Auth', desired_level: :info)

    assert_equal 1, captured.size
    assert_equal LOG_LEVEL_KEY, captured.first[:key]
    ctx = captured.first[:jit_context]
    assert_equal({ 'quonfig-sdk-logging' => { 'key' => 'MyApp::Services::Auth' } }, ctx)
  end

  def test_should_log_merges_caller_contexts_with_logger_context
    store = store_with(make_log_level_config(key: LOG_LEVEL_KEY, level: 'trace'))
    client = client_with(store, logger_key: LOG_LEVEL_KEY)

    captured = []
    client.define_singleton_method(:get) do |key, default = nil, jit_context = nil|
      captured << jit_context
      'trace'
    end

    client.should_log?(
      logger_path: 'MyApp::Foo',
      desired_level: :info,
      contexts: { 'user' => { 'id' => 'u1' } }
    )

    assert_equal(
      {
        'user' => { 'id' => 'u1' },
        'quonfig-sdk-logging' => { 'key' => 'MyApp::Foo' }
      },
      captured.first
    )
  end

  def test_should_log_logger_path_verbatim_no_normalization
    store = store_with(make_log_level_config(key: LOG_LEVEL_KEY, level: 'trace'))
    client = client_with(store, logger_key: LOG_LEVEL_KEY)

    captured = []
    client.define_singleton_method(:get) do |key, default = nil, jit_context = nil|
      captured << jit_context
      'trace'
    end

    client.should_log?(logger_path: 'HTMLParser', desired_level: :info)
    assert_equal 'HTMLParser', captured.first['quonfig-sdk-logging']['key']
  end
end
