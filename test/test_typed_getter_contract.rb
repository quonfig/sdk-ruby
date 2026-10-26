# frozen_string_literal: true

require 'test_helper'

# The typed-getter contract (qfg-zvyy) on the paths the integration-test-data
# matrix (getter.contract.*) cannot reach: the once-per-key WARN, enabled?
# never raising, int <-> double edges JSON cannot store, the Details error
# codes, and the untyped get / get_or_raise.
class TestTypedGetterContract < Minitest::Test
  KEY = 'contract.key'
  ENV_KEY = 'QFG_TYPED_GETTER_CONTRACT'
  Details = Quonfig::EvaluationDetails
  WARN = /\[quonfig\] read of "contract.key" returned no value: /

  def make_config(value:, type:, key: KEY)
    {
      'id' => '1',
      'key' => key,
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

  def client_for(*configs, **opts)
    store = Quonfig::ConfigStore.new
    configs.each { |c| store.set(c['key'], c) }
    Quonfig::Client.new(Quonfig::Options.new(**opts), store: store)
  end

  def client_with_value(value:, type:, **opts)
    client_for(make_config(value: value, type: type), **opts)
  end

  def provided_client(type:, **opts)
    config = make_config(value: nil, type: type)
    config['default']['rules'][0]['value'] = {
      'type' => 'provided', 'value' => { 'source' => 'ENV_VAR', 'lookup' => ENV_KEY }
    }
    client_for(config, **opts)
  end

  def secret_client(**opts)
    ciphertext = Quonfig::Encryption.new('0' * 64).encrypt('hello.world')
    key_cfg = make_config(value: '1' * 64, type: 'string', key: 'wrong.key') # not the key it was encrypted with
    secret_cfg = make_config(value: ciphertext, type: 'string')
    secret_cfg['default']['rules'][0]['value'].merge!('confidential' => true, 'decryptWith' => 'wrong.key')
    client_for(key_cfg, secret_cfg, **opts)
  end

  def warn_lines
    $logs.string.lines.grep(WARN)
  end

  # ---- default / nil / raise ---------------------------------------------

  def test_wrong_type_returns_default_and_logs_once_per_key
    client = client_with_value(value: 'fast', type: 'string')
    3.times { assert_equal 7, client.get_int(KEY, default: 7) }
    assert_equal true, client.get_bool(KEY, default: true)
    assert_equal 1, warn_lines.size, $logs.string
    assert_logged([WARN])
  end

  def test_each_key_logs_its_own_warning
    client = client_for(make_config(value: 'a', type: 'string'),
                        make_config(value: 'b', type: 'string', key: 'contract.other'))
    client.get_int(KEY, default: 1)
    client.get_int('contract.other', default: 1)
    client.get_int('contract.other', default: 1)
    assert_equal 2, $logs.string.lines.grep(/returned no value/).size, $logs.string
    assert_logged([WARN, /read of "contract.other" returned no value/])
  end

  def test_each_client_logs_its_own_warning
    2.times { client_with_value(value: 'a', type: 'string').get_int(KEY, default: 1) }
    assert_equal 2, warn_lines.size
    assert_logged([WARN])
  end

  def test_wrong_type_with_no_default_returns_nil_under_return_nil
    client = client_with_value(value: 'fast', type: 'string', on_no_default: :return_nil)
    assert_nil client.get_int(KEY)
    assert_logged([WARN])
  end

  def test_wrong_type_with_no_default_raises_under_raise_without_logging
    client = client_with_value(value: 'fast', type: 'string')
    err = assert_raises(Quonfig::Errors::TypeMismatchError) { client.get_int(KEY) }
    assert_equal "Quonfig value for key 'contract.key' expected Integer, got a string value", err.message
    assert_empty $logs.string
  end

  # The value used to bypass the type check when it was equal? to the default.
  def test_no_identity_bypass_when_value_equals_default
    client = client_with_value(value: true, type: 'bool')
    assert_equal true, client.get_string(KEY, default: true)
    assert_logged([/expected String, got a bool value/])
  end

  def test_missing_env_var_returns_default
    with_env(ENV_KEY, nil) do
      client = provided_client(type: 'string')
      assert_equal 'd', client.get_string(KEY, default: 'd')
      assert_equal 'd', client.get(KEY, 'd')
      assert_raises(Quonfig::Errors::MissingEnvVarError) { client.get_string(KEY) }
      assert_raises(Quonfig::Errors::MissingEnvVarError) { client.get_or_raise(KEY, default: 'd') }
    end
    assert_logged([/Environment variable "#{ENV_KEY}" not set/])
  end

  def test_malformed_env_var_int_returns_default
    with_env(ENV_KEY, 'twelve') do
      client = provided_client(type: 'int')
      assert_equal 5, client.get_int(KEY, default: 5)
      assert_raises(Quonfig::Errors::EnvVarParseError) { client.get_int(KEY) }
    end
    assert_logged([/cannot be converted to int/])
  end

  def test_decryption_failure_returns_default_and_get_or_raise_raises
    client = secret_client
    assert_equal 'fallback', client.get_string(KEY, default: 'fallback')
    assert_equal 'fallback', client.get(KEY, 'fallback')
    assert_raises(Quonfig::Errors::DecryptionError) { client.get_string(KEY) }
    assert_raises(Quonfig::Errors::DecryptionError) { client.get_or_raise(KEY) }
    assert_logged([/Decryption failed/])
  end

  def test_malformed_stored_int
    client = client_with_value(value: 'twelve', type: 'int')
    assert_equal 4, client.get_int(KEY, default: 4)
    assert_equal 4, client.get(KEY, 4)
    assert_raises(Quonfig::Errors::EnvVarParseError) { client.get_int(KEY) }
    assert_raises(Quonfig::Errors::EnvVarParseError) { client.get_or_raise(KEY) }
    assert_logged([/stored value cannot be converted to int/])
  end

  def test_malformed_stored_double
    client = client_with_value(value: 'abc', type: 'double', on_no_default: :return_nil)
    assert_nil client.get_float(KEY)
    assert_logged([/stored value cannot be converted to double/])
  end

  # ---- no string coercion ------------------------------------------------

  def test_stored_string_false_is_not_a_bool
    client = client_with_value(value: 'false', type: 'string')
    assert_equal true, client.get_bool(KEY, default: true)
    assert_equal 'false', client.get_string(KEY)
    assert_logged([/expected Boolean, got a string value/])
  end

  def test_stored_string_number_is_not_a_number
    client = client_with_value(value: '3', type: 'string')
    assert_equal 9, client.get_int(KEY, default: 9)
    assert_in_delta 9.5, client.get_float(KEY, default: 9.5)
    assert_logged([WARN])
  end

  # ---- int <-> double ------------------------------------------------------

  def test_double_getter_on_int
    value = client_with_value(value: 30, type: 'int').get_float(KEY)
    assert_kind_of Float, value
    assert_in_delta 30.0, value
  end

  def test_int_getter_on_whole_doubles
    { 3.0 => 3, -3.0 => -3, 0.0 => 0, ((2**53) - 1).to_f => (2**53) - 1, -((2**53) - 1).to_f => -((2**53) - 1) }.each do |stored, want|
      got = client_with_value(value: stored, type: 'double').get_int(KEY)
      assert_kind_of Integer, got
      assert_equal want, got, "get_int on #{stored}"
    end
  end

  def test_int_getter_never_truncates
    [3.9, -0.5, (2**53).to_f, -(2**53).to_f, 1e300, Float::NAN, Float::INFINITY, -Float::INFINITY].each do |stored|
      client = client_with_value(value: stored, type: 'double')
      assert_equal(-1, client.get_int(KEY, default: -1), "get_int on #{stored}")
      assert_raises(Quonfig::Errors::TypeMismatchError, "get_int on #{stored}") { client.get_int(KEY) }
    end
    assert_logged([WARN])
  end

  # A stored int Value whose raw number is fractional must not truncate.
  def test_int_value_with_fractional_raw_is_a_mismatch
    client = client_with_value(value: 1.9, type: 'int')
    assert_equal 0, client.get_int(KEY, default: 0)
    assert_logged([WARN])
  end

  # ---- enabled? never raises ---------------------------------------------

  def test_enabled_true_only_for_bool_true
    assert client_with_value(value: true, type: 'bool').enabled?(KEY)
    refute client_with_value(value: false, type: 'bool').enabled?(KEY)
  end

  def test_enabled_false_for_non_bool_values
    [%w[true string], [1, 'int'], [['true'], 'string_list']].each do |value, type|
      refute client_with_value(value: value, type: type).enabled?(KEY), "enabled? on #{type} #{value.inspect}"
    end
    assert_logged([/enabled\? returns false/])
  end

  def test_enabled_never_raises_on_resolution_errors
    with_env(ENV_KEY, nil) { refute provided_client(type: 'bool').enabled?(KEY) }
    with_env(ENV_KEY, 'maybe') { refute provided_client(type: 'bool').enabled?(KEY) }
    refute secret_client.enabled?(KEY)
    assert_logged([/not set/, /Decryption failed/])
  end

  def test_enabled_false_when_no_rule_matches_and_logs_once
    config = make_config(value: true, type: 'bool')
    config['default']['rules'][0]['criteria'] =
      [{ 'propertyName' => 'user.key', 'operator' => 'PROP_IS_ONE_OF', 'valueToMatch' => { 'type' => 'string_list', 'value' => ['u1'] } }]
    client = client_for(config)
    3.times { refute client.enabled?(KEY) }
    assert client.enabled?(KEY, { 'user' => { 'key' => 'u1' } })
    assert_equal 1, warn_lines.size, $logs.string
    assert_logged([/missing key or no matching rule/])
  end

  def test_bound_client_enabled_never_raises
    with_env(ENV_KEY, nil) do
      refute provided_client(type: 'bool').with_context('user' => { 'key' => 'u' }).enabled?(KEY)
    end
    assert_logged([WARN])
  end

  # ---- details -------------------------------------------------------------

  def test_details_type_mismatch
    [
      [:get_int_details, 3.9, 'double'],
      [:get_bool_details, 'false', 'string'],
      [:get_string_details, 3, 'int'],
      [:get_json_details, 'x', 'string'],
      [:get_string_list_details, { 'a' => 1 }, 'json'],
      [:get_int_details, 'twelve', 'int']
    ].each do |getter, value, type|
      details = client_with_value(value: value, type: type).public_send(getter, KEY)
      assert_nil details.value, getter
      assert_equal Details::REASON_ERROR, details.reason, getter
      assert_equal Details::ERROR_TYPE_MISMATCH, details.error_code, "#{getter} on #{type} #{value.inspect}"
    end
  end

  def test_details_safe_conversions
    assert_equal 3, client_with_value(value: 3.0, type: 'double').get_int_details(KEY).value
    assert_in_delta 30.0, client_with_value(value: 30, type: 'int').get_float_details(KEY).value
  end

  def test_details_malformed_env_var_is_type_mismatch
    with_env(ENV_KEY, 'twelve') do
      details = provided_client(type: 'int').get_int_details(KEY)
      assert_equal Details::REASON_ERROR, details.reason
      assert_equal Details::ERROR_TYPE_MISMATCH, details.error_code
    end
  end
end
