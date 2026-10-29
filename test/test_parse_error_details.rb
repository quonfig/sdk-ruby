# frozen_string_literal: true

require 'test_helper'

# qfg-wg1n: the details API reports a value that cannot be parsed as its
# declared type (a malformed ENV_VAR value, a malformed stored int / double /
# duration) as error_code PARSE_ERROR. A value of another type is still
# TYPE_MISMATCH. OpenFeature providers pass PARSE_ERROR straight through.
class TestParseErrorDetails < Minitest::Test
  Details = Quonfig::EvaluationDetails
  KEY = 'parse.error.subject'
  ENV_KEY = 'QUONFIG_TEST_PARSE_ERROR_DETAILS'

  def make_config(value:, type:)
    {
      'id' => "cid-#{KEY}", 'key' => KEY, 'type' => 'config', 'valueType' => type,
      'sendToClientSdk' => false, 'environment' => nil,
      'default' => { 'rules' => [{ 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
                                   'value' => { 'type' => type, 'value' => value } }] }
    }
  end

  def client_for(config, **opts)
    store = Quonfig::ConfigStore.new
    store.set(config['key'], config)
    Quonfig::Client.new(Quonfig::Options.new(**opts), store: store)
  end

  def stored_client(value:, type:)
    client_for(make_config(value: value, type: type))
  end

  def env_client(type:)
    config = make_config(value: nil, type: type)
    config['default']['rules'][0]['value'] = {
      'type' => 'provided', 'value' => { 'source' => 'ENV_VAR', 'lookup' => ENV_KEY }
    }
    client_for(config)
  end

  def with_env(name, value)
    old = ENV.fetch(name, nil)
    value.nil? ? ENV.delete(name) : ENV[name] = value
    yield
  ensure
    old.nil? ? ENV.delete(name) : ENV[name] = old
  end

  def assert_parse_error(details, label)
    assert_nil details.value, label
    assert_equal Details::REASON_ERROR, details.reason, label
    assert_equal Details::ERROR_PARSE_ERROR, details.error_code, label
    assert_equal 'default', details.variant, label
    refute_nil details.error_message, label
  end

  def test_parse_error_constant
    assert_equal 'PARSE_ERROR', Details::ERROR_PARSE_ERROR
  end

  # ---- malformed ENV_VAR value -------------------------------------------

  ENV_CASES = [
    ['int', 'twelve', %i[get_int_details get_float_details]],
    ['double', 'abc', %i[get_float_details get_int_details]],
    ['duration', 'PT5S garbage', %i[get_duration_details]]
  ].freeze

  def test_malformed_env_var_is_parse_error_on_typed_getters
    ENV_CASES.each do |type, env_value, getters|
      with_env(ENV_KEY, env_value) do
        getters.each do |getter|
          assert_parse_error(env_client(type: type).public_send(getter, KEY), "#{getter} on ENV_VAR #{type}")
        end
      end
    end
  end

  def test_malformed_env_var_is_parse_error_on_evaluate_details
    ENV_CASES.each do |type, env_value, _|
      with_env(ENV_KEY, env_value) do
        assert_parse_error(env_client(type: type).evaluate_details(KEY), "evaluate_details on ENV_VAR #{type}")
      end
    end
  end

  def test_malformed_env_var_is_parse_error_on_bound_client
    with_env(ENV_KEY, 'twelve') do
      bound = env_client(type: 'int').with_context('user' => { 'key' => 'u' })
      assert_parse_error(bound.get_int_details(KEY), 'bound get_int_details')
      assert_parse_error(bound.evaluate_details(KEY), 'bound evaluate_details')
    end
  end

  # ---- malformed stored value --------------------------------------------

  def test_malformed_stored_value_is_parse_error_on_typed_getters
    [
      ['int', 'twelve', %i[get_int_details get_float_details]],
      ['double', 'abc', %i[get_float_details get_int_details]],
      ['duration', 'PT0.5H', %i[get_duration_details]],
      ['duration', '30s', %i[get_duration_details]]
    ].each do |type, value, getters|
      getters.each do |getter|
        details = stored_client(value: value, type: type).public_send(getter, KEY)
        assert_parse_error(details, "#{getter} on stored #{type} #{value.inspect}")
        assert_equal "cid-#{KEY}", details.flag_metadata['config_id'], getter
      end
    end
  end

  # evaluate_details does no parse validation (2.1.0 contract): a malformed
  # stored value comes back as stored with a success reason.
  def test_evaluate_details_returns_malformed_stored_value_as_is
    details = stored_client(value: 'twelve', type: 'int').evaluate_details(KEY)
    assert_equal 'twelve', details.value
    assert_equal Details::REASON_STATIC, details.reason
    assert_nil details.error_code
  end

  # ---- a real type mismatch stays TYPE_MISMATCH --------------------------

  def test_value_of_another_type_is_still_type_mismatch
    [
      [:get_int_details, 'hello', 'string'],
      [:get_int_details, 3.9, 'double'],
      [:get_bool_details, 'false', 'string'],
      [:get_duration_details, 5000, 'int'],
      [:get_string_details, 'twelve', 'int'] # wrong type wins over malformed
    ].each do |getter, value, type|
      details = stored_client(value: value, type: type).public_send(getter, KEY)
      assert_equal Details::REASON_ERROR, details.reason, getter
      assert_equal Details::ERROR_TYPE_MISMATCH, details.error_code, "#{getter} on #{type} #{value.inspect}"
    end
  end

  def test_well_formed_env_var_still_resolves
    with_env(ENV_KEY, '42') do
      details = env_client(type: 'int').get_int_details(KEY)
      assert_equal 42, details.value
      assert_nil details.error_code
    end
  end
end
