# frozen_string_literal: true

require 'test_helper'
require 'semantic_logger'

class TestSemanticLoggerFilter < Minitest::Test
  def setup
    super
    @client = new_client
  end

  # Build a LOG_LEVEL_V2 config that resolves to `level` for everyone.
  def log_level_config(key, level)
    PrefabProto::Config.new(
      key: key,
      id: key.hash.abs,
      config_type: PrefabProto::ConfigType::LOG_LEVEL_V2,
      value_type: PrefabProto::Config::ValueType::LOG_LEVEL,
      rows: [
        PrefabProto::ConfigRow.new(
          values: [
            PrefabProto::ConditionalValue.new(
              value: PrefabProto::ConfigValue.new(log_level: level)
            )
          ]
        )
      ]
    )
  end

  def make_log(name, level)
    SemanticLogger::Log.new(name, level).tap do |log|
      log.level = level
    end
  end

  def test_exact_match_passes_configured_level_through
    inject_config(@client, log_level_config('log-levels.my_app.foo.bar', PrefabProto::LogLevel::INFO))
    filter = @client.semantic_logger_filter

    assert_equal true, filter.call(make_log('MyApp::Foo::Bar', :info))
    assert_equal true, filter.call(make_log('MyApp::Foo::Bar', :warn))
    assert_equal true, filter.call(make_log('MyApp::Foo::Bar', :error))
    assert_equal true, filter.call(make_log('MyApp::Foo::Bar', :fatal))
  end

  def test_exact_match_suppresses_below_configured_level
    inject_config(@client, log_level_config('log-levels.my_app.foo.bar', PrefabProto::LogLevel::WARN))
    filter = @client.semantic_logger_filter

    assert_equal false, filter.call(make_log('MyApp::Foo::Bar', :trace))
    assert_equal false, filter.call(make_log('MyApp::Foo::Bar', :debug))
    assert_equal false, filter.call(make_log('MyApp::Foo::Bar', :info))
    assert_equal true,  filter.call(make_log('MyApp::Foo::Bar', :warn))
  end

  def test_missing_key_falls_through_to_semantic_logger_default
    filter = @client.semantic_logger_filter

    # No config set — filter should allow the log through (return true)
    # so SemanticLogger's static level decides.
    assert_equal true, filter.call(make_log('MyApp::Foo::Bar', :trace))
    assert_equal true, filter.call(make_log('MyApp::Foo::Bar', :debug))
    assert_equal true, filter.call(make_log('MyApp::Foo::Bar', :info))
  end

  def test_no_hierarchy_walk
    # Parent is set to WARN but the child (log-levels.my_app.foo.bar) is NOT set.
    # Old Reforge logic would walk up and apply WARN; new logic must NOT.
    inject_config(@client, log_level_config('log-levels.my_app', PrefabProto::LogLevel::WARN))
    filter = @client.semantic_logger_filter

    # A :debug log on the child — would be suppressed by WARN if hierarchy
    # walking were in place. Exact-match behavior returns true (fall-through).
    assert_equal true, filter.call(make_log('MyApp::Foo::Bar', :debug))
  end

  def test_logger_name_normalization
    # MyApp::Foo::Bar → my_app.foo.bar
    inject_config(@client, log_level_config('log-levels.my_app.foo.bar', PrefabProto::LogLevel::ERROR))
    filter = @client.semantic_logger_filter

    # :info is below :error → must be suppressed, proving the key matched.
    assert_equal false, filter.call(make_log('MyApp::Foo::Bar', :info))

    # Also prove CamelCase→snake_case: HTMLParser → html_parser
    inject_config(@client, log_level_config('log-levels.html_parser', PrefabProto::LogLevel::FATAL))
    assert_equal false, filter.call(make_log('HTMLParser', :error))
  end

  def test_custom_key_prefix
    inject_config(@client, log_level_config('custom.my_app.foo.bar', PrefabProto::LogLevel::ERROR))
    filter = @client.semantic_logger_filter(key_prefix: 'custom.')

    assert_equal false, filter.call(make_log('MyApp::Foo::Bar', :info))
    assert_equal true,  filter.call(make_log('MyApp::Foo::Bar', :error))
  end

  def test_context_passes_through
    # Build a config whose level depends on user.role = 'admin'.
    key = 'log-levels.my_app.foo.bar'
    config = PrefabProto::Config.new(
      key: key,
      id: 99,
      config_type: PrefabProto::ConfigType::LOG_LEVEL_V2,
      value_type: PrefabProto::Config::ValueType::LOG_LEVEL,
      rows: [
        PrefabProto::ConfigRow.new(
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_IS_ONE_OF,
                  property_name: 'user.role',
                  value_to_match: string_list(['admin'])
                )
              ],
              value: PrefabProto::ConfigValue.new(log_level: PrefabProto::LogLevel::TRACE)
            ),
            PrefabProto::ConditionalValue.new(
              value: PrefabProto::ConfigValue.new(log_level: PrefabProto::LogLevel::ERROR)
            )
          ]
        )
      ]
    )
    inject_config(@client, config)
    filter = @client.semantic_logger_filter

    # No context → ERROR level → :info suppressed
    assert_equal false, filter.call(make_log('MyApp::Foo::Bar', :info))

    # With admin context → TRACE level → :info passes
    @client.with_context(user: { role: 'admin' }) do
      assert_equal true, filter.call(make_log('MyApp::Foo::Bar', :info))
    end
  end

  def test_raises_loaderror_when_semantic_logger_missing
    skip unless defined?(Quonfig::SemanticLoggerFilter)

    Quonfig::SemanticLoggerFilter.stub(:semantic_logger_loaded?, false) do
      err = assert_raises(LoadError) { @client.semantic_logger_filter }
      assert_match(/semantic_logger/i, err.message)
    end
  end

  def test_all_six_levels_mapped
    levels = {
      trace: 0,
      debug: 1,
      info:  2,
      warn:  3,
      error: 4,
      fatal: 5
    }

    levels.each do |name, expected|
      assert_equal expected, Quonfig::SemanticLoggerFilter::LEVELS[name],
                   "Level :#{name} should map to #{expected}"
    end
  end

  def test_module_helper_returns_a_filter
    # Quonfig.semantic_logger_filter should return a filter on the global singleton.
    Quonfig.instance_variable_set(:@singleton, @client)
    filter = Quonfig.semantic_logger_filter
    assert_respond_to filter, :call
  ensure
    Quonfig.instance_variable_set(:@singleton, nil)
  end
end
