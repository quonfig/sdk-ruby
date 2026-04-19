# frozen_string_literal: true

require 'test_helper'

class TestLocalConfigParser < Minitest::Test
  FILE_NAME = 'example-config.yaml'
  DEFAULT_MATCH = 'default'

  def setup
    super
    @mock_resolver = MockResolver.new
  end

  def test_parse_int_config
    key = :sample_int
    parsed = Quonfig::LocalConfigParser.parse(key, 123, {}, FILE_NAME)[key]
    config = parsed[:config]

    assert_equal FILE_NAME, parsed[:source]
    assert_equal DEFAULT_MATCH, parsed[:match]
    assert_equal :CONFIG, config.config_type
    assert_equal key.to_s, config.key
    assert_equal 1, config.rows.size
    assert_equal 1, config.rows[0].values.size
    assert_equal 123, config.rows[0].values[0].value.int
  end

  def test_flag_with_a_value
    key = :flag_with_a_value
    value = stringify_keys({ feature_flag: true, value: 'all-features' })
    parsed = Quonfig::LocalConfigParser.parse(key, value, {}, FILE_NAME)[key]
    config = parsed[:config]

    assert_equal FILE_NAME, parsed[:source]
    assert_equal key, parsed[:match]
    assert_equal :FEATURE_FLAG, config.config_type
    assert_equal key.to_s, config.key
    assert_equal 1, config.rows.size
    assert_equal 1, config.rows[0].values.size

    value_row = config.rows[0].values[0]
    assert_equal 'all-features', Quonfig::ConfigValueUnwrapper.deepest_value(value_row.value, key, {}, @mock_resolver).unwrap
  end

  def test_flag_in_user_key
    key = :flag_in_user_key
    value = stringify_keys({ 'feature_flag': 'true', value: true,
                             criterion: { operator: 'PROP_IS_ONE_OF', property: 'user.key', values: %w[abc123 xyz987] } })
    parsed = Quonfig::LocalConfigParser.parse(key, value, {}, FILE_NAME)[key]
    config = parsed[:config]

    assert_equal FILE_NAME, parsed[:source]
    assert_equal key, parsed[:match]
    assert_equal :FEATURE_FLAG, config.config_type
    assert_equal key.to_s, config.key
    assert_equal 1, config.rows.size
    assert_equal 1, config.rows[0].values.size
    assert_equal 1, config.rows[0].values[0].criteria.size

    value_row = config.rows[0].values[0]
    assert_equal true, Quonfig::ConfigValueUnwrapper.deepest_value(value_row.value, key, {}, @mock_resolver).unwrap

    assert_equal 'user.key', value_row.criteria[0].property_name
    assert_equal :PROP_IS_ONE_OF, value_row.criteria[0].operator
    assert_equal %w[abc123 xyz987], value_row.criteria[0].value_to_match.string_list.values
  end

  def test_provided_values
    with_env('LOOKUP_ENV', 'from env') do 
      key = :test_provided
      value = stringify_keys({type: 'provided', source: 'ENV_VAR', lookup: 'LOOKUP_ENV'})
      parsed = Quonfig::LocalConfigParser.parse(key, value, {}, FILE_NAME)[key]
      config = parsed[:config]

      assert_equal FILE_NAME, parsed[:source]
      assert_equal 'LOOKUP_ENV', parsed[:match]
      assert_equal :CONFIG, config.config_type
      assert_equal key.to_s, config.key
      assert_equal 1, config.rows.size
      assert_equal 1, config.rows[0].values.size
      
      value_row = config.rows[0].values[0]            
      provided = value_row.value.provided
      assert_equal :ENV_VAR, provided.source
      assert_equal 'LOOKUP_ENV', provided.lookup
      assert_equal 'from env', Quonfig::ConfigValueUnwrapper.deepest_value(value_row.value, config, {}, @mock_resolver).unwrap
      reportable_value = Quonfig::ConfigValueUnwrapper.deepest_value(value_row.value, config, {}, @mock_resolver).reportable_value
      assert_equal 'from env', reportable_value
    end
  end

  def test_confidential_provided_values
    with_env('LOOKUP_ENV', 'from env') do
      key = :test_provided
      value = stringify_keys({type: 'provided', source: 'ENV_VAR', lookup: 'LOOKUP_ENV', confidential: true})
      parsed = Quonfig::LocalConfigParser.parse(key, value, {}, FILE_NAME)[key]
      config = parsed[:config]

      value_row = config.rows[0].values[0]
      provided = value_row.value.provided
      assert_equal :ENV_VAR, provided.source
      assert_equal 'LOOKUP_ENV', provided.lookup
      assert_equal 'from env', Quonfig::ConfigValueUnwrapper.deepest_value(value_row.value, config, {}, @mock_resolver).unwrap
      reportable_value = Quonfig::ConfigValueUnwrapper.deepest_value(value_row.value, config, {}, @mock_resolver).reportable_value
      assert reportable_value.start_with? Quonfig::ConfigValueUnwrapper::CONFIDENTIAL_PREFIX
    end
  end

  def test_confidential_values
    key = :test_confidential
    value = stringify_keys({value: 'a confidential string', confidential: true})
    parsed = Quonfig::LocalConfigParser.parse(key, value, {}, FILE_NAME)[key]
    config = parsed[:config]

    assert_equal FILE_NAME, parsed[:source]
    assert_equal :CONFIG, config.config_type
    assert_equal key.to_s, config.key
    assert_equal 1, config.rows.size
    assert_equal 1, config.rows[0].values.size

    value_row = config.rows[0].values[0]
    config_value = value_row.value
    assert_equal 'a confidential string', Quonfig::ConfigValueUnwrapper.deepest_value(config_value, key, {}, @mock_resolver).unwrap
    reportable_value = Quonfig::ConfigValueUnwrapper.deepest_value(config_value, key, {}, @mock_resolver).reportable_value
    assert reportable_value.start_with? Quonfig::ConfigValueUnwrapper::CONFIDENTIAL_PREFIX
  end

  private

  def stringify_keys(hash)
    deep_transform_keys(hash, &:to_s)
  end

  def deep_transform_keys(hash, &block)
    result = {}
    hash.each do |key, value|
      result[yield(key)] = value.is_a?(Hash) ? deep_transform_keys(value, &block) : value
    end
    result
  end

  class MockResolver
    def get(key)
      raise "unexpected key"
    end
  end
end
