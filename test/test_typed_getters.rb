# frozen_string_literal: true

require 'test_helper'

# Typed getters (get_string / get_int / get_bool / get_string_list /
# get_duration / get_json) on Quonfig::Client. Each verifies both the happy
# path against an injected ConfigStore and the type-mismatch error path.
class TestTypedGetters < Minitest::Test
  KEY = 'my.key'

  def make_config(value:, type:)
    {
      'id' => '1',
      'key' => KEY,
      'type' => 'config',
      'valueType' => type,
      'sendToClientSdk' => false,
      'default' => {
        'rules' => [
          {
            'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
            'value' => { 'type' => type, 'value' => value }
          }
        ]
      },
      'environment' => nil
    }
  end

  def client_with_value(value:, type:)
    store = Quonfig::ConfigStore.new
    store.set(KEY, make_config(value: value, type: type))
    Quonfig::Client.new(Quonfig::Options.new, store: store)
  end

  # ---- get_string -------------------------------------------------------

  def test_get_string_returns_string
    assert_equal 'hello', client_with_value(value: 'hello', type: 'string').get_string(KEY)
  end

  def test_get_string_raises_on_non_string
    assert_raises(Quonfig::Errors::TypeMismatchError) do
      client_with_value(value: 42, type: 'int').get_string(KEY)
    end
  end

  def test_get_string_default_when_missing
    client = Quonfig::Client.new(Quonfig::Options.new, store: Quonfig::ConfigStore.new)
    assert_equal 'fallback', client.get_string('nope', default: 'fallback')
  end

  # ---- get_int ----------------------------------------------------------

  def test_get_int_returns_integer
    assert_equal 42, client_with_value(value: 42, type: 'int').get_int(KEY)
  end

  def test_get_int_raises_on_string
    assert_raises(Quonfig::Errors::TypeMismatchError) do
      client_with_value(value: 'oops', type: 'string').get_int(KEY)
    end
  end

  # ---- get_float --------------------------------------------------------

  def test_get_float_returns_float
    assert_in_delta 3.14, client_with_value(value: 3.14, type: 'double').get_float(KEY), 0.0001
  end

  def test_get_float_raises_on_non_float
    assert_raises(Quonfig::Errors::TypeMismatchError) do
      client_with_value(value: 'oops', type: 'string').get_float(KEY)
    end
  end

  # ---- get_bool ---------------------------------------------------------

  def test_get_bool_returns_true
    assert_equal true, client_with_value(value: true, type: 'bool').get_bool(KEY)
  end

  def test_get_bool_returns_false
    assert_equal false, client_with_value(value: false, type: 'bool').get_bool(KEY)
  end

  def test_get_bool_raises_on_string
    assert_raises(Quonfig::Errors::TypeMismatchError) do
      client_with_value(value: 'true', type: 'string').get_bool(KEY)
    end
  end

  # ---- get_string_list --------------------------------------------------

  def test_get_string_list_returns_array_of_strings
    assert_equal %w[a b c], client_with_value(value: %w[a b c], type: 'string_list').get_string_list(KEY)
  end

  def test_get_string_list_raises_on_non_array
    assert_raises(Quonfig::Errors::TypeMismatchError) do
      client_with_value(value: 'a,b,c', type: 'string').get_string_list(KEY)
    end
  end

  # ---- get_duration -----------------------------------------------------

  def test_get_duration_returns_milliseconds_for_iso_string
    # ISO-8601 PT1S -> 1 second -> 1000 ms.
    client = client_with_value(value: 'PT1S', type: 'duration')
    assert_equal 1000, client.get_duration(KEY)
  end

  def test_get_duration_passes_through_numeric
    client = client_with_value(value: 5000, type: 'int')
    assert_equal 5000, client.get_duration(KEY)
  end

  # ---- get_json ---------------------------------------------------------

  def test_get_json_returns_hash_unchanged
    payload = { 'a' => 1, 'b' => [1, 2, 3] }
    client = client_with_value(value: payload, type: 'json')
    assert_equal payload, client.get_json(KEY)
  end

  def test_get_json_returns_array_unchanged
    payload = [1, 2, 3]
    client = client_with_value(value: payload, type: 'json')
    assert_equal payload, client.get_json(KEY)
  end
end
