# frozen_string_literal: true

require 'test_helper'

# Client#evaluate_details (qfg-177f): the untyped details read, matching
# sdk-go's Client.EvaluateDetails. It returns the resolved value in its
# stored form (after ENV_VAR provision and decryption) with no type check,
# coercion or parse validation, plus the same reason / variant /
# flag_metadata the typed *_details getters report, and +value_type+ (the
# stored value type) on the details. It never raises.
class TestEvaluateDetails < Minitest::Test
  Details = Quonfig::EvaluationDetails
  KEY = 'eval.details.subject'
  ENV_KEY = 'QUONFIG_TEST_EVALUATE_DETAILS'

  def rule(value, criteria = [{ 'operator' => 'ALWAYS_TRUE' }])
    { 'criteria' => criteria, 'value' => value }
  end

  def config(rules:, type:, key: KEY)
    {
      'id' => "cid-#{key}", 'key' => key, 'type' => 'config', 'valueType' => type,
      'sendToClientSdk' => false, 'environment' => nil,
      'default' => { 'rules' => rules }
    }
  end

  def client_for(*configs, **opts)
    store = Quonfig::ConfigStore.new
    configs.each { |c| store.set(c['key'], c) }
    Quonfig::Client.new(Quonfig::Options.new(**opts), store: store)
  end

  def static_client(value:, type:)
    client_for(config(rules: [rule({ 'type' => type, 'value' => value })], type: type))
  end

  def with_env(name, value)
    old = ENV.fetch(name, nil)
    value.nil? ? ENV.delete(name) : ENV[name] = value
    yield
  ensure
    old.nil? ? ENV.delete(name) : ENV[name] = old
  end

  # ---- durations keep their stored ISO text ---------------------------

  def test_static_duration_returns_stored_iso_text_unchanged
    details = static_client(value: 'PT90S', type: 'duration').evaluate_details(KEY)
    assert_equal 'PT90S', details.value
    assert_equal Details::REASON_STATIC, details.reason
    assert_equal 'static', details.variant
    assert_nil details.error_code
    assert_equal 'duration', details.value_type
    assert_equal "cid-#{KEY}", details.flag_metadata['config_id']
  end

  def test_compound_duration_is_not_renormalized
    details = static_client(value: 'P1DT6H2M1.5S', type: 'duration').evaluate_details(KEY)
    assert_equal 'P1DT6H2M1.5S', details.value
    assert_equal Details::REASON_STATIC, details.reason
  end

  def test_malformed_duration_is_returned_raw_with_success_reason
    client = static_client(value: '30s', type: 'duration')
    details = client.evaluate_details(KEY)
    assert_equal '30s', details.value
    assert_equal Details::REASON_STATIC, details.reason
    assert_nil details.error_code
    # The typed getter is unchanged: still an error.
    assert_equal Details::ERROR_TYPE_MISMATCH, client.get_duration_details(KEY).error_code
  end

  # ---- other value types -----------------------------------------------

  def test_other_types_return_stored_form_with_value_type
    {
      'string' => 'hi', 'int' => 42, 'double' => 1.5, 'bool' => false,
      'string_list' => %w[a b], 'json' => { 'a' => [1, 2] }
    }.each do |type, value|
      details = static_client(value: value, type: type).evaluate_details(KEY)
      assert_equal value, details.value, type
      assert_equal type, details.value_type, type
      assert_equal Details::REASON_STATIC, details.reason, type
    end
  end

  def test_mutating_a_returned_container_does_not_change_config
    client = static_client(value: { 'a' => [1] }, type: 'json')
    client.evaluate_details(KEY).value['a'] << 2
    assert_equal({ 'a' => [1] }, client.evaluate_details(KEY).value)
  end

  # ---- targeting and splits --------------------------------------------

  def test_targeting_match_reason_and_variant
    match = [{ 'propertyName' => 'user.plan', 'operator' => 'PROP_IS_ONE_OF',
               'valueToMatch' => { 'type' => 'string_list', 'value' => ['pro'] } }]
    client = client_for(config(type: 'duration', rules: [
                                 rule({ 'type' => 'duration', 'value' => 'PT5M' }, match),
                                 rule({ 'type' => 'duration', 'value' => 'PT1M' })
                               ]))

    pro = client.evaluate_details(KEY, context: { 'user' => { 'plan' => 'pro' } })
    assert_equal 'PT5M', pro.value
    assert_equal Details::REASON_TARGETING_MATCH, pro.reason
    assert_equal 'targeting:0', pro.variant
    assert_equal 0, pro.flag_metadata['rule_index']

    free = client.evaluate_details(KEY, context: { 'user' => { 'plan' => 'free' } })
    assert_equal 'PT1M', free.value
    assert_equal 'targeting:1', free.variant
  end

  def test_bound_client_and_global_context_merge_like_typed_details
    match = [{ 'propertyName' => 'user.plan', 'operator' => 'PROP_IS_ONE_OF',
               'valueToMatch' => { 'type' => 'string_list', 'value' => ['pro'] } }]
    cfg = config(type: 'string', rules: [rule({ 'type' => 'string', 'value' => 'gold' }, match),
                                         rule({ 'type' => 'string', 'value' => 'tin' })])
    global = client_for(cfg, global_context: { 'user' => { 'plan' => 'pro' } })
    assert_equal 'gold', global.evaluate_details(KEY).value

    bound = client_for(cfg).with_context('user' => { 'plan' => 'pro' })
    details = bound.evaluate_details(KEY)
    assert_equal 'gold', details.value
    assert_equal bound.get_string_details(KEY).variant, details.variant
  end

  def test_weighted_split_reason_and_variant
    wv = { 'hashByPropertyName' => 'user.id', 'weightedValues' => [
      { 'weight' => 1, 'value' => { 'type' => 'duration', 'value' => 'PT1S' } },
      { 'weight' => 1, 'value' => { 'type' => 'duration', 'value' => 'PT2S' } }
    ] }
    client = client_for(config(type: 'duration',
                               rules: [rule({ 'type' => 'weighted_values', 'value' => wv })]))
    ctx = { 'user' => { 'id' => 'user-123' } }

    details = client.evaluate_details(KEY, context: ctx)
    assert_equal Details::REASON_SPLIT, details.reason
    assert_includes %w[PT1S PT2S], details.value
    index = details.flag_metadata['weighted_value_index']
    assert_equal "split:#{index}", details.variant
    assert_equal %w[PT1S PT2S][index], details.value
    assert_equal client.get_duration_details(KEY, context: ctx).variant, details.variant
  end

  # ---- ENV_VAR and secrets ---------------------------------------------

  def test_env_var_provided_duration_returns_env_text
    provided = { 'type' => 'provided', 'value' => { 'source' => 'ENV_VAR', 'lookup' => ENV_KEY } }
    client = client_for(config(type: 'duration', rules: [rule(provided)]))
    with_env(ENV_KEY, 'PT45S') do
      details = client.evaluate_details(KEY)
      assert_equal 'PT45S', details.value
      assert_equal Details::REASON_STATIC, details.reason
      assert_equal 'duration', details.value_type
    end
  end

  def test_unset_env_var_is_error_details_not_a_raise
    provided = { 'type' => 'provided', 'value' => { 'source' => 'ENV_VAR', 'lookup' => ENV_KEY } }
    client = client_for(config(type: 'string', rules: [rule(provided)]))
    with_env(ENV_KEY, nil) do
      details = client.evaluate_details(KEY)
      assert_nil details.value
      assert_equal Details::REASON_ERROR, details.reason
      assert_equal client.get_string_details(KEY).error_code, details.error_code
    end
  end

  def test_decrypted_secret_returns_plaintext
    secret_key = '0' * 64
    ciphertext = Quonfig::Encryption.new(secret_key).encrypt('hello.world')
    key_cfg = config(key: 'eval.details.key', type: 'string',
                     rules: [rule({ 'type' => 'string', 'value' => secret_key })])
    secret_cfg = config(type: 'string', rules: [rule({ 'type' => 'string', 'value' => ciphertext,
                                                       'confidential' => true,
                                                       'decryptWith' => 'eval.details.key' })])
    details = client_for(key_cfg, secret_cfg).evaluate_details(KEY)
    assert_equal 'hello.world', details.value
    assert_equal Details::REASON_STATIC, details.reason
  end

  # ---- missing key -------------------------------------------------------

  def test_missing_key_matches_typed_details
    client = client_for
    details = client.evaluate_details('no.such.key')
    typed = client.get_string_details('no.such.key')
    assert_nil details.value
    assert_equal typed.reason, details.reason
    assert_equal Details::ERROR_FLAG_NOT_FOUND, details.error_code
    assert_equal typed.error_code, details.error_code
    assert_equal typed.variant, details.variant
    assert_nil details.value_type
  end

  def test_typed_details_leave_value_type_nil
    assert_nil static_client(value: 'hi', type: 'string').get_string_details(KEY).value_type
  end
end
