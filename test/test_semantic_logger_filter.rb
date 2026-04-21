# frozen_string_literal: true

require 'test_helper'
require 'semantic_logger'

# Verifies the corrected design: ONE Quonfig config gates many loggers.
# The filter passes `quonfig.logger-name` as a context property so customer
# rules can target `PROP_STARTS_WITH_ONE_OF my_app.db` etc.
class TestSemanticLoggerFilter < Minitest::Test
  CONFIG_KEY = 'log-levels.my-app'

  # FakeClient lets us assert the exact key + context the filter passes to
  # the SDK without standing up a full datadir. The single-key contract is
  # the *specific mechanism* this bead is verifying — if the filter ever
  # regresses to a per-logger key, this captured request goes wrong.
  class FakeClient
    attr_reader :calls

    def initialize(level)
      @level = level
      @calls = []
    end

    def get(key, default = nil, context = nil)
      @calls << { key: key, default: default, context: context }
      @level.nil? ? default : @level
    end
  end

  def make_log(name, level)
    SemanticLogger::Log.new(name, level).tap { |log| log.level = level }
  end

  def filter_for(level)
    client = FakeClient.new(level)
    [Quonfig::SemanticLoggerFilter.new(client, config_key: CONFIG_KEY), client]
  end

  def test_calls_single_config_key_with_logger_name_in_context
    filter, client = filter_for(:info)
    filter.call(make_log('MyApp::Foo::Bar', :warn))

    assert_equal 1, client.calls.size
    assert_equal CONFIG_KEY, client.calls.first[:key]
    ctx = client.calls.first[:context]
    assert_equal({ 'quonfig' => { 'logger-name' => 'my_app.foo.bar' } }, ctx)
  end

  def test_passes_through_when_level_meets_configured_minimum
    filter, _ = filter_for(:info)

    assert_equal true, filter.call(make_log('Anything', :info))
    assert_equal true, filter.call(make_log('Anything', :warn))
    assert_equal true, filter.call(make_log('Anything', :error))
    assert_equal true, filter.call(make_log('Anything', :fatal))
  end

  def test_suppresses_below_configured_minimum
    filter, _ = filter_for(:warn)

    assert_equal false, filter.call(make_log('Anything', :trace))
    assert_equal false, filter.call(make_log('Anything', :debug))
    assert_equal false, filter.call(make_log('Anything', :info))
    assert_equal true,  filter.call(make_log('Anything', :warn))
  end

  def test_missing_key_falls_through_to_semantic_logger_default
    filter, _ = filter_for(nil) # FakeClient returns the default (nil) when configured level is nil

    assert_equal true, filter.call(make_log('Anything', :trace))
    assert_equal true, filter.call(make_log('Anything', :debug))
  end

  def test_logger_name_normalization
    filter, client = filter_for(:debug)

    {
      'MyApp::Foo::Bar' => 'my_app.foo.bar',
      'HTMLParser'      => 'html_parser',
      'foo'             => 'foo',
      'A::B::CDPath'    => 'a.b.cd_path'
    }.each do |raw, expected|
      client.calls.clear
      filter.call(make_log(raw, :info))
      assert_equal expected, client.calls.first[:context]['quonfig']['logger-name'],
                   "normalize(#{raw.inspect}) should be #{expected.inspect}"
    end
  end

  def test_no_dotted_path_traversal_or_get_log_level
    # Verifies the legacy hierarchical walk is gone — the filter must NOT
    # synthesize keys like "log-levels.my_app" or call any `get_log_level`.
    refute Quonfig::SemanticLoggerFilter.instance_methods.include?(:get_log_level)

    filter, client = filter_for(:info)
    filter.call(make_log('MyApp::Foo::Bar', :info))

    keys = client.calls.map { |c| c[:key] }
    assert_equal [CONFIG_KEY], keys.uniq,
                 'Filter should call exactly the configured key, never derived per-logger keys'
  end

  def test_all_six_levels_mapped_correctly
    expected = { trace: 0, debug: 1, info: 2, warn: 3, error: 4, fatal: 5 }
    assert_equal expected, Quonfig::SemanticLoggerFilter::LEVELS
  end

  def test_string_level_from_config
    filter, _ = filter_for('warn')

    assert_equal false, filter.call(make_log('Anything', :info))
    assert_equal true,  filter.call(make_log('Anything', :warn))
  end

  def test_raises_loaderror_when_semantic_logger_missing
    Quonfig::SemanticLoggerFilter.stub(:semantic_logger_loaded?, false) do
      err = assert_raises(LoadError) do
        Quonfig::SemanticLoggerFilter.new(FakeClient.new(:info), config_key: CONFIG_KEY)
      end
      assert_match(/semantic_logger/i, err.message)
    end
  end
end
