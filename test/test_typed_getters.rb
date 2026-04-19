# frozen_string_literal: true

require 'test_helper'

class TestTypedGetters < Minitest::Test
  LOCAL_ONLY = Quonfig::Options::DATASOURCES::LOCAL_ONLY
  PROJECT_ENV_ID = 1

  STRING_KEY       = 'str.key'
  INT_KEY          = 'int.key'
  FLOAT_KEY        = 'float.key'
  BOOL_KEY         = 'bool.key'
  STRING_LIST_KEY  = 'list.key'
  DURATION_KEY     = 'duration.key'
  JSON_KEY         = 'json.key'

  def test_get_string_returns_string
    client = client_with(STRING_KEY, PrefabProto::ConfigValue.new(string: 'hello'))
    assert_equal 'hello', client.get_string(STRING_KEY)
    assert_kind_of String, client.get_string(STRING_KEY)
  end

  def test_get_int_returns_integer
    client = client_with(INT_KEY, PrefabProto::ConfigValue.new(int: 42))
    assert_equal 42, client.get_int(INT_KEY)
    assert_kind_of Integer, client.get_int(INT_KEY)
  end

  def test_get_float_returns_float
    client = client_with(FLOAT_KEY, PrefabProto::ConfigValue.new(double: 3.14))
    assert_in_delta 3.14, client.get_float(FLOAT_KEY), 0.0001
    assert_kind_of Float, client.get_float(FLOAT_KEY)
  end

  def test_get_bool_returns_bool
    client = client_with(BOOL_KEY, PrefabProto::ConfigValue.new(bool: true))
    assert_equal true, client.get_bool(BOOL_KEY)
  end

  def test_get_string_list_returns_array_of_strings
    client = client_with(
      STRING_LIST_KEY,
      PrefabProto::ConfigValue.new(string_list: PrefabProto::StringList.new(values: %w[a b c]))
    )
    assert_equal %w[a b c], client.get_string_list(STRING_LIST_KEY)
  end

  def test_get_duration_returns_milliseconds
    client = client_with(
      DURATION_KEY,
      PrefabProto::ConfigValue.new(duration: PrefabProto::IsoDuration.new(definition: 'PT5M'))
    )
    # 5 minutes = 300_000 ms
    assert_equal 300_000, client.get_duration(DURATION_KEY)
    assert_kind_of Integer, client.get_duration(DURATION_KEY)
  end

  def test_get_json_returns_hash
    client = client_with(
      JSON_KEY,
      PrefabProto::ConfigValue.new(json: PrefabProto::Json.new(json: '{"k":"v","n":1}'))
    )
    assert_equal({ 'k' => 'v', 'n' => 1 }, client.get_json(JSON_KEY))
  end

  def test_typed_getter_raises_type_mismatch
    client = client_with(STRING_KEY, PrefabProto::ConfigValue.new(string: 'not an int'))
    err = assert_raises(Quonfig::Errors::TypeMismatchError) do
      client.get_int(STRING_KEY)
    end
    assert_match(/expected Integer/, err.message)
  end

  def test_typed_getter_returns_default_when_missing
    client = new_client
    assert_equal 'fallback', client.get_string('no.such.key', default: 'fallback')
    assert_equal 99, client.get_int('no.such.key', default: 99)
    assert_equal false, client.get_bool('no.such.key', default: false)
  end

  def test_typed_getter_raises_when_missing_without_default
    client = new_client
    assert_raises(Quonfig::Errors::MissingDefaultError) do
      client.get_string('no.such.key')
    end
  end

  def test_typed_getter_returns_nil_when_missing_and_on_no_default_return_nil
    client = new_client(on_no_default: Quonfig::Options::ON_NO_DEFAULT::RETURN_NIL)
    assert_nil client.get_string('no.such.key')
    assert_nil client.get_int('no.such.key')
  end

  def test_in_context_yields_bound_client_and_scopes_context
    client = client_with_basic_string_config

    result = client.in_context(user: { 'key' => 99 }) do |bound|
      assert_kind_of Quonfig::BoundClient, bound
      bound.get_string('str.key')
    end

    assert_equal 'desired', result
  end

  def test_with_context_returns_bound_client
    client = client_with_basic_string_config
    bound = client.with_context(user: { 'key' => 99 })
    assert_kind_of Quonfig::BoundClient, bound
    assert_equal 'desired', bound.get_string('str.key')
  end

  def test_bound_client_applies_context_on_typed_getter
    # Config that returns 'desired' only when user.key == 99, else 'default'
    config = PrefabProto::Config.new(
      id: 7,
      key: 'str.key',
      config_type: PrefabProto::ConfigType::CONFIG,
      rows: [
        PrefabProto::ConfigRow.new(
          values: [
            PrefabProto::ConditionalValue.new(value: PrefabProto::ConfigValue.new(string: 'default'))
          ]
        ),
        PrefabProto::ConfigRow.new(
          project_env_id: PROJECT_ENV_ID,
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [
                PrefabProto::Criterion.new(
                  operator: PrefabProto::Criterion::CriterionOperator::PROP_IS_ONE_OF,
                  value_to_match: PrefabProto::ConfigValue.new(
                    string_list: PrefabProto::StringList.new(values: ['99'])
                  ),
                  property_name: 'user.key'
                )
              ],
              value: PrefabProto::ConfigValue.new(string: 'desired')
            )
          ]
        )
      ]
    )

    client = new_client(config: config, project_env_id: PROJECT_ENV_ID)

    # Without context — default row
    assert_equal 'default', client.get_string('str.key')

    # Bound to user.key=99 — desired row
    bound = client.with_context(user: { 'key' => '99' })
    assert_equal 'desired', bound.get_string('str.key')

    # Client itself unchanged after bind
    assert_equal 'default', client.get_string('str.key')
  end

  private

  def single_value_config(key, value)
    PrefabProto::Config.new(
      id: key.hash.abs,
      key: key,
      config_type: PrefabProto::ConfigType::CONFIG,
      rows: [
        PrefabProto::ConfigRow.new(
          values: [PrefabProto::ConditionalValue.new(value: value)]
        )
      ]
    )
  end

  def client_with(key, value)
    new_client(config: single_value_config(key, value), project_env_id: PROJECT_ENV_ID)
  end

  def client_with_basic_string_config
    config = PrefabProto::Config.new(
      id: 123,
      key: 'str.key',
      config_type: PrefabProto::ConfigType::CONFIG,
      rows: [
        PrefabProto::ConfigRow.new(
          values: [PrefabProto::ConditionalValue.new(value: PrefabProto::ConfigValue.new(string: 'desired'))]
        )
      ]
    )
    new_client(config: config, project_env_id: PROJECT_ENV_ID)
  end
end
