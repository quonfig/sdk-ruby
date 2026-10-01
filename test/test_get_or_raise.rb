# frozen_string_literal: true

require 'test_helper'

# Public Client#get_or_raise and Client#get_duration_details (qfg-2agi.27),
# plus their BoundClient counterparts.
class TestClientGetOrRaise < Minitest::Test
  KEY = 'my.key'
  ENV_KEY = 'QFG_GET_OR_RAISE_TEST'
  Details = Quonfig::EvaluationDetails

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

  def client_for(config, **opts)
    store = Quonfig::ConfigStore.new
    store.set(KEY, config) if config
    Quonfig::Client.new(Quonfig::Options.new(**opts), store: store)
  end

  def client_with_value(value:, type:, **opts)
    client_for(make_config(value: value, type: type), **opts)
  end

  def provided_client(type:)
    config = make_config(value: nil, type: type)
    config['default']['rules'][0]['value'] = {
      'type' => 'provided', 'value' => { 'source' => 'ENV_VAR', 'lookup' => ENV_KEY }
    }
    client_for(config)
  end

  def quietly(&block)
    Quonfig::Client::LOG.stub(:warn, ->(*_args, &_) {}, &block)
  end

  # ---- get_or_raise -----------------------------------------------------

  def test_get_or_raise_returns_value
    assert_equal 'hello', client_with_value(value: 'hello', type: 'string').get_or_raise(KEY)
  end

  def test_get_or_raise_raises_missing_default_even_under_return_nil
    client = client_for(nil, on_no_default: :return_nil)
    assert_nil client.get('nope')
    err = assert_raises(Quonfig::Errors::MissingDefaultError) { client.get_or_raise('nope') }
    assert_includes err.message, 'nope'
  end

  def test_get_or_raise_returns_default_when_missing
    assert_equal 'DEFAULT', client_for(nil).get_or_raise('nope', default: 'DEFAULT')
  end

  def test_get_or_raise_raises_missing_env_var
    with_env(ENV_KEY, nil) do
      assert_raises(Quonfig::Errors::MissingEnvVarError) { provided_client(type: 'string').get_or_raise(KEY) }
    end
  end

  def test_get_or_raise_raises_on_uncoercible_env_var
    with_env(ENV_KEY, 'not-a-number') do
      assert_raises(Quonfig::Errors::EnvVarParseError) { provided_client(type: 'int').get_or_raise(KEY) }
    end
  end

  def test_get_or_raise_returns_duration_millis
    assert_equal 30_000, client_with_value(value: 'PT30S', type: 'duration').get_or_raise(KEY)
  end

  # Decision 3: get_or_raise raises the coercion error on a malformed value,
  # stored or ENV_VAR.
  def test_get_or_raise_raises_on_malformed_stored_duration
    quietly do
      assert_raises(Quonfig::Errors::EnvVarParseError) do
        client_with_value(value: '30s', type: 'duration').get_or_raise(KEY, default: 5)
      end
    end
  end

  def test_get_or_raise_raises_on_malformed_env_var_duration
    with_env(ENV_KEY, 'P1DT') do
      quietly do
        assert_raises(Quonfig::Errors::EnvVarParseError) { provided_client(type: 'duration').get_or_raise(KEY) }
      end
    end
  end

  def test_bound_client_get_or_raise
    bound = client_with_value(value: 7, type: 'int').in_context('user' => { 'key' => 'u1' })
    assert_equal 7, bound.get_or_raise(KEY)
    assert_raises(Quonfig::Errors::MissingDefaultError) { bound.get_or_raise('nope') }
    assert_equal 1, bound.get_or_raise('nope', default: 1)
  end

  # ---- get_duration_details ---------------------------------------------

  def test_get_duration_details_returns_millis
    details = client_with_value(value: 'PT1.005S', type: 'duration').get_duration_details(KEY)
    assert_equal 1005, details.value
    assert_equal Details::REASON_STATIC, details.reason
    assert_nil details.error_code
  end

  def test_get_duration_details_env_var
    with_env(ENV_KEY, 'PT2S') do
      assert_equal 2000, provided_client(type: 'duration').get_duration_details(KEY).value
    end
  end

  def test_get_duration_details_type_mismatch_on_int_config
    details = client_with_value(value: 5000, type: 'int').get_duration_details(KEY)
    assert_nil details.value
    assert_equal Details::REASON_ERROR, details.reason
    assert_equal Details::ERROR_TYPE_MISMATCH, details.error_code
  end

  def test_get_duration_details_type_mismatch_on_string_config
    details = client_with_value(value: 'PT5S', type: 'string').get_duration_details(KEY)
    assert_equal Details::REASON_ERROR, details.reason
    assert_equal Details::ERROR_TYPE_MISMATCH, details.error_code
  end

  def test_get_duration_details_error_on_malformed_stored
    details = quietly { client_with_value(value: 'PT0.5H', type: 'duration').get_duration_details(KEY) }
    assert_nil details.value
    assert_equal Details::REASON_ERROR, details.reason
    refute_nil details.error_code
  end

  def test_get_duration_details_error_on_malformed_env_var
    with_env(ENV_KEY, 'PT5S garbage') do
      details = quietly { provided_client(type: 'duration').get_duration_details(KEY) }
      assert_nil details.value
      assert_equal Details::REASON_ERROR, details.reason
    end
  end

  def test_get_duration_details_missing_key
    details = client_for(nil).get_duration_details('nope')
    assert_equal Details::REASON_ERROR, details.reason
    assert_equal Details::ERROR_FLAG_NOT_FOUND, details.error_code
  end

  def test_bound_client_get_duration_details
    bound = client_with_value(value: 'PT1M', type: 'duration').in_context('user' => { 'key' => 'u1' })
    assert_equal 60_000, bound.get_duration_details(KEY).value
  end
end
