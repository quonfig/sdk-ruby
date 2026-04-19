# frozen_string_literal: true

require 'test_helper'

class TestLogLevelClient < Minitest::Test
  def setup
    super
    @options = Quonfig::Options.new(
      prefab_datasources: Quonfig::Options::DATASOURCES::LOCAL_ONLY,
      logger_key: 'test.log.level.key'
    )

    @client = Quonfig::Client.new(@options)
  end

  def test_get_log_level_returns_debug_when_no_config_exists
    log_level = @client.log_level_client.get_log_level('MyApp::MyClass')
    assert_equal :debug, log_level
  end

  def test_get_log_level_with_log_level_v2_config
    # Create a LOG_LEVEL_V2 config
    config = PrefabProto::Config.new(
      key: 'test.log.level.key',
      id: 1,
      config_type: PrefabProto::ConfigType::LOG_LEVEL_V2,
      value_type: PrefabProto::Config::ValueType::LOG_LEVEL,
      rows: [
        PrefabProto::ConfigRow.new(
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_IS_ONE_OF,
                  property_name: 'quonfig-sdk-logging.logger-path',
                  value_to_match: PrefabProto::ConfigValue.new(
                    string_list: PrefabProto::StringList.new(values: ['MyApp::DebugClass'])
                  )
                )
              ],
              value: PrefabProto::ConfigValue.new(log_level: PrefabProto::LogLevel::DEBUG)
            ),
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_IS_ONE_OF,
                  property_name: 'quonfig-sdk-logging.logger-path',
                  value_to_match: PrefabProto::ConfigValue.new(
                    string_list: PrefabProto::StringList.new(values: ['MyApp::InfoClass'])
                  )
                )
              ],
              value: PrefabProto::ConfigValue.new(log_level: PrefabProto::LogLevel::INFO)
            ),
            # Default case - WARN for everything else
            PrefabProto::ConditionalValue.new(
              value: PrefabProto::ConfigValue.new(log_level: PrefabProto::LogLevel::WARN)
            )
          ]
        )
      ]
    )

    # Load the config into the resolver
    @client.config_client.resolver.instance_variable_get(:@config_loader).set(config, :test)
    @client.config_client.resolver.update

    # Test that we get DEBUG for MyApp::DebugClass
    log_level = @client.log_level_client.get_log_level('MyApp::DebugClass')
    assert_equal :debug, log_level

    # Test that we get INFO for MyApp::InfoClass
    log_level = @client.log_level_client.get_log_level('MyApp::InfoClass')
    assert_equal :info, log_level

    # Test that we get WARN for anything else (default)
    log_level = @client.log_level_client.get_log_level('MyApp::OtherClass')
    assert_equal :warn, log_level
  end

  def test_get_log_level_with_all_log_levels
    # Create a LOG_LEVEL_V2 config with all log levels
    config = PrefabProto::Config.new(
      key: 'test.log.level.key',
      id: 1,
      config_type: PrefabProto::ConfigType::LOG_LEVEL_V2,
      value_type: PrefabProto::Config::ValueType::LOG_LEVEL,
      rows: [
        PrefabProto::ConfigRow.new(
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_IS_ONE_OF,
                  property_name: 'quonfig-sdk-logging.logger-path',
                  value_to_match: PrefabProto::ConfigValue.new(
                    string_list: PrefabProto::StringList.new(values: ['TraceLogger'])
                  )
                )
              ],
              value: PrefabProto::ConfigValue.new(log_level: PrefabProto::LogLevel::TRACE)
            ),
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_IS_ONE_OF,
                  property_name: 'quonfig-sdk-logging.logger-path',
                  value_to_match: PrefabProto::ConfigValue.new(
                    string_list: PrefabProto::StringList.new(values: ['ErrorLogger'])
                  )
                )
              ],
              value: PrefabProto::ConfigValue.new(log_level: PrefabProto::LogLevel::ERROR)
            ),
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_IS_ONE_OF,
                  property_name: 'quonfig-sdk-logging.logger-path',
                  value_to_match: PrefabProto::ConfigValue.new(
                    string_list: PrefabProto::StringList.new(values: ['FatalLogger'])
                  )
                )
              ],
              value: PrefabProto::ConfigValue.new(log_level: PrefabProto::LogLevel::FATAL)
            )
          ]
        )
      ]
    )

    # Load the config into the resolver
    @client.config_client.resolver.instance_variable_get(:@config_loader).set(config, :test)
    @client.config_client.resolver.update

    # Test all log levels
    assert_equal :trace, @client.log_level_client.get_log_level('TraceLogger')
    assert_equal :error, @client.log_level_client.get_log_level('ErrorLogger')
    assert_equal :fatal, @client.log_level_client.get_log_level('FatalLogger')
  end

  def test_get_log_level_returns_debug_when_logger_key_is_nil
    options = Quonfig::Options.new(
      prefab_datasources: Quonfig::Options::DATASOURCES::LOCAL_ONLY,
      logger_key: nil
    )
    client = Quonfig::Client.new(options)

    log_level = client.log_level_client.get_log_level('MyApp::MyClass')
    assert_equal :debug, log_level
  end

  def test_get_log_level_returns_debug_when_logger_key_is_empty
    options = Quonfig::Options.new(
      prefab_datasources: Quonfig::Options::DATASOURCES::LOCAL_ONLY,
      logger_key: ''
    )
    client = Quonfig::Client.new(options)

    log_level = client.log_level_client.get_log_level('MyApp::MyClass')
    assert_equal :debug, log_level
  end

  def test_get_log_level_returns_debug_when_config_is_wrong_type
    # Create a regular CONFIG type instead of LOG_LEVEL_V2
    config = PrefabProto::Config.new(
      key: 'test.log.level.key',
      id: 1,
      config_type: PrefabProto::ConfigType::CONFIG,
      value_type: PrefabProto::Config::ValueType::STRING,
      rows: [
        PrefabProto::ConfigRow.new(
          values: [
            PrefabProto::ConditionalValue.new(
              value: PrefabProto::ConfigValue.new(string: 'not a log level')
            )
          ]
        )
      ]
    )

    # Load the config into the resolver
    @client.config_client.resolver.instance_variable_get(:@config_loader).set(config, :test)
    @client.config_client.resolver.update

    log_level = @client.log_level_client.get_log_level('MyApp::MyClass')
    assert_equal :debug, log_level
    assert_logged [/Config 'test.log.level.key' is not a LOG_LEVEL_V2 config/]
  end

  def test_log_level_enum_from_proto
    assert_equal :trace, Quonfig::LogLevel.from_proto(PrefabProto::LogLevel::TRACE)
    assert_equal :debug, Quonfig::LogLevel.from_proto(PrefabProto::LogLevel::DEBUG)
    assert_equal :info, Quonfig::LogLevel.from_proto(PrefabProto::LogLevel::INFO)
    assert_equal :warn, Quonfig::LogLevel.from_proto(PrefabProto::LogLevel::WARN)
    assert_equal :error, Quonfig::LogLevel.from_proto(PrefabProto::LogLevel::ERROR)
    assert_equal :fatal, Quonfig::LogLevel.from_proto(PrefabProto::LogLevel::FATAL)
    assert_equal :debug, Quonfig::LogLevel.from_proto(PrefabProto::LogLevel::NOT_SET_LOG_LEVEL)
  end

  def test_default_logger_key
    options = Quonfig::Options.new(
      prefab_datasources: Quonfig::Options::DATASOURCES::LOCAL_ONLY
    )

    assert_equal 'log-levels.default', options.logger_key
  end

  def test_should_log_with_different_severities
    # Create a LOG_LEVEL_V2 config set to INFO
    config = PrefabProto::Config.new(
      key: 'test.log.level.key',
      id: 1,
      config_type: PrefabProto::ConfigType::LOG_LEVEL_V2,
      value_type: PrefabProto::Config::ValueType::LOG_LEVEL,
      rows: [
        PrefabProto::ConfigRow.new(
          values: [
            PrefabProto::ConditionalValue.new(
              value: PrefabProto::ConfigValue.new(log_level: PrefabProto::LogLevel::INFO)
            )
          ]
        )
      ]
    )

    @client.config_client.resolver.instance_variable_get(:@config_loader).set(config, :test)
    @client.config_client.resolver.update

    # SemanticLogger levels: trace=0, debug=1, info=2, warn=3, error=4, fatal=5
    # With INFO level set, we should log INFO (2) and above, but not DEBUG (1) or TRACE (0)
    assert_equal false, @client.log_level_client.should_log?(0, 'MyApp::MyClass'), 'TRACE should not log'
    assert_equal false, @client.log_level_client.should_log?(1, 'MyApp::MyClass'), 'DEBUG should not log'
    assert_equal true, @client.log_level_client.should_log?(2, 'MyApp::MyClass'), 'INFO should log'
    assert_equal true, @client.log_level_client.should_log?(3, 'MyApp::MyClass'), 'WARN should log'
    assert_equal true, @client.log_level_client.should_log?(4, 'MyApp::MyClass'), 'ERROR should log'
    assert_equal true, @client.log_level_client.should_log?(5, 'MyApp::MyClass'), 'FATAL should log'
  end

  def test_class_path_name_conversion
    client = @client.log_level_client

    # Test underscore conversion
    assert_equal 'my_app.my_class', client.send(:class_path_name, 'MyApp::MyClass')
  end

  def test_underscore
    client = @client.log_level_client

    assert_equal 'my_app/my_class', client.send(:underscore, 'MyApp::MyClass')
    assert_equal 'html_parser', client.send(:underscore, 'HTMLParser')
    assert_equal 'my_simple_class', client.send(:underscore, 'MySimpleClass')
  end

  def test_semantic_logger_levels_mapping
    # Verify our SEMANTIC_LOGGER_LEVELS constant matches expectations
    assert_equal 0, Quonfig::LogLevelClient::SEMANTIC_LOGGER_LEVELS[:trace]
    assert_equal 1, Quonfig::LogLevelClient::SEMANTIC_LOGGER_LEVELS[:debug]
    assert_equal 2, Quonfig::LogLevelClient::SEMANTIC_LOGGER_LEVELS[:info]
    assert_equal 3, Quonfig::LogLevelClient::SEMANTIC_LOGGER_LEVELS[:warn]
    assert_equal 4, Quonfig::LogLevelClient::SEMANTIC_LOGGER_LEVELS[:error]
    assert_equal 5, Quonfig::LogLevelClient::SEMANTIC_LOGGER_LEVELS[:fatal]
  end
end
