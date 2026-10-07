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

  def provided_duration_client
    config = make_config(value: nil, type: 'duration')
    config['default']['rules'][0]['value'] = {
      'type' => 'provided', 'value' => { 'source' => 'ENV_VAR', 'lookup' => 'QFG_TYPED_GETTER_DURATION' }
    }
    store = Quonfig::ConfigStore.new
    store.set(KEY, config)
    Quonfig::Client.new(Quonfig::Options.new, store: store)
  end

  def capture_client_warns(&block)
    warns = []
    Quonfig::Client::LOG.stub(:warn, ->(msg = nil, &_) { warns << msg }, &block)
    warns
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

  # get_duration type-checks like get_int (qfg-2agi.10): a config whose
  # valueType is not duration is a TypeMismatchError, not a pass-through.
  def test_get_duration_raises_on_int_config
    assert_raises(Quonfig::Errors::TypeMismatchError) do
      client_with_value(value: 5000, type: 'int').get_duration(KEY)
    end
  end

  def test_get_duration_raises_on_double_config
    assert_raises(Quonfig::Errors::TypeMismatchError) do
      client_with_value(value: 1.9, type: 'double').get_duration(KEY)
    end
  end

  def test_get_duration_raises_on_string_config
    assert_raises(Quonfig::Errors::TypeMismatchError) do
      client_with_value(value: 'PT5S', type: 'string').get_duration(KEY)
    end
  end

  # Round half up to integer ms (qfg-2agi decision 2), stored path.
  def test_get_duration_rounds_half_up_stored
    assert_equal 1005, client_with_value(value: 'PT1.005S', type: 'duration').get_duration(KEY)
    assert_equal 2000, client_with_value(value: 'PT1.9999S', type: 'duration').get_duration(KEY)
    assert_equal 1, client_with_value(value: 'PT0.0005S', type: 'duration').get_duration(KEY)
    assert_equal 0, client_with_value(value: 'PT0.0004S', type: 'duration').get_duration(KEY)
  end

  # Same rounding on the ENV_VAR-provided path (it used to truncate: 1999).
  def test_get_duration_rounds_half_up_env_var
    with_env('QFG_TYPED_GETTER_DURATION', 'PT1.9999S') do
      assert_equal 2000, provided_duration_client.get_duration(KEY)
    end
  end

  # Malformed stored value: default + one warning per key; no default under
  # :return_nil -> nil; under the default :raise policy -> coercion error.
  def test_get_duration_malformed_stored_returns_default_and_warns_once
    client = client_with_value(value: '30s', type: 'duration')
    warns = capture_client_warns do
      assert_equal 7000, client.get_duration(KEY, default: 7000)
      assert_equal 7000, client.get_duration(KEY, default: 7000)
    end
    assert_equal 1, warns.size, warns.inspect
    assert_includes warns.first, KEY
  end

  def test_get_duration_malformed_stored_no_default
    store = Quonfig::ConfigStore.new
    store.set(KEY, make_config(value: 'PT0.5H', type: 'duration'))
    nil_client = Quonfig::Client.new(Quonfig::Options.new(on_no_default: :return_nil), store: store)
    raise_client = Quonfig::Client.new(Quonfig::Options.new, store: store)
    capture_client_warns do
      assert_nil nil_client.get_duration(KEY)
      assert_raises(Quonfig::Errors::EnvVarParseError) { raise_client.get_duration(KEY) }
    end
  end

  def test_get_duration_malformed_env_var_returns_default
    with_env('QFG_TYPED_GETTER_DURATION', 'P1DT') do
      capture_client_warns do
        assert_equal 7000, provided_duration_client.get_duration(KEY, default: 7000)
      end
    end
  end

  # qfg-2agi.22: get() on an ENV_VAR-provided duration returns ms, the same
  # as the stored value (it used to return the raw ISO string).
  def test_get_on_env_var_duration_returns_millis_like_stored
    with_env('QFG_TYPED_GETTER_DURATION', 'PT30M') do
      assert_equal 1_800_000, provided_duration_client.get(KEY)
      assert_equal 1_800_000, client_with_value(value: 'PT30M', type: 'duration').get(KEY)
    end
    with_env('QFG_TYPED_GETTER_DURATION', 'PT1.5S') do
      assert_equal 1500, provided_duration_client.get(KEY)
      assert_equal 1500, provided_duration_client.get_duration(KEY)
    end
  end

  def test_get_duration_never_returns_the_raw_string_from_get
    client = client_with_value(value: 'garbage', type: 'duration')
    assert_nil client.get(KEY)
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
  # ---- error messages never carry the value (qfg-goi1.2.11) -------------

  # A decryptWith secret read through the wrong typed getter must not put the
  # decrypted plaintext into the exception message or into
  # *_details.error_message (both end up in logs and error trackers).
  def secret_client
    hex_key = Quonfig::Encryption.generate_new_hex_key
    ciphertext = Quonfig::Encryption.new(hex_key).encrypt('hello.world')
    store = Quonfig::ConfigStore.new
    key_cfg = make_config(value: hex_key, type: 'string')
    key_cfg['key'] = 'the.key'
    store.set('the.key', key_cfg)
    secret_cfg = make_config(value: ciphertext, type: 'string')
    secret_cfg['default']['rules'][0]['value'].merge!('confidential' => true, 'decryptWith' => 'the.key')
    store.set(KEY, secret_cfg)
    Quonfig::Client.new(Quonfig::Options.new, store: store)
  end

  def test_type_mismatch_message_omits_decrypted_secret
    client = secret_client
    assert_equal 'hello.world', client.get_string(KEY)

    err = assert_raises(Quonfig::Errors::TypeMismatchError) { client.get_int(KEY, default: 0) }
    refute_includes err.message, 'hello.world'
    assert_includes err.message, KEY
    assert_includes err.message, 'Integer'
    assert_includes err.message, 'String'

    details = client.get_int_details(KEY)
    refute_nil details.error_message
    refute_includes details.error_message, 'hello.world'
  end

  def test_type_mismatch_message_has_no_doubled_expected
    err = assert_raises(Quonfig::Errors::TypeMismatchError) do
      client_with_value(value: 'oops', type: 'string').get_int(KEY)
    end
    refute_match(/expected expected/, err.message)
    refute_includes err.message, 'oops'
  end

  def test_type_mismatch_messages_omit_value_for_every_getter
    { get_bool: 'string-secret', get_string_list: 'string-secret', get_duration: 'string-secret' }.each do |getter, v|
      err = assert_raises(Quonfig::Errors::TypeMismatchError) do
        client_with_value(value: v, type: 'string').public_send(getter, KEY)
      end
      refute_includes err.message, v, "#{getter}: #{err.message}"
    end
  end

  def test_malformed_stored_duration_error_omits_stored_value
    client = client_with_value(value: 'not-a-duration-secret', type: 'duration')
    err = nil
    capture_client_warns do
      err = assert_raises(Quonfig::Errors::EnvVarParseError) { client.get_duration(KEY) }
    end
    refute_includes err.message, 'not-a-duration-secret'
    assert_includes err.message, KEY
    assert_includes err.message, 'duration'
  end
end
