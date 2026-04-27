# frozen_string_literal: true

require 'test_helper'

# Coverage for the *_details getters on Quonfig::Client and Quonfig::BoundClient.
# These return Quonfig::EvaluationDetails carrying an OpenFeature-aligned
# +reason+ and (on the error path) error_code / error_message. They never raise.
class TestDetailsGetters < Minitest::Test
  Details = Quonfig::EvaluationDetails

  INTEGRATION_FIXTURE_DIR = File.expand_path(
    '../../integration-test-data/data/integration-tests', __dir__
  )

  # ---- Helpers --------------------------------------------------------

  def fixture_client
    skip "integration-test-data sibling missing at #{INTEGRATION_FIXTURE_DIR}" unless Dir.exist?(INTEGRATION_FIXTURE_DIR)

    Quonfig::Client.new(
      Quonfig::Options.new(
        datadir: INTEGRATION_FIXTURE_DIR,
        environment: 'Production',
        enable_sse: false,
        enable_polling: false
      )
    )
  end

  # An ALWAYS_TRUE-only config: no targeting rules anywhere -> STATIC.
  def make_static_config(key:, value:, type:)
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

  def static_client(key:, value:, type:)
    store = Quonfig::ConfigStore.new
    store.set(key, make_static_config(key: key, value: value, type: type))
    Quonfig::Client.new(Quonfig::Options.new, store: store)
  end

  # ---- STATIC reason --------------------------------------------------

  def test_get_bool_details_static_reason_for_always_true_only_config
    client = static_client(key: 'plain', value: true, type: 'bool')
    details = client.get_bool_details('plain')
    assert_kind_of Details, details
    assert_equal true, details.value
    assert_equal Details::REASON_STATIC, details.reason
    assert_nil details.error_code
    assert_nil details.error_message
  end

  def test_get_string_details_static_reason
    client = static_client(key: 'plain.s', value: 'hi', type: 'string')
    details = client.get_string_details('plain.s')
    assert_equal 'hi', details.value
    assert_equal Details::REASON_STATIC, details.reason
  end

  def test_static_reason_via_integration_fixture_always_true
    client = fixture_client
    details = client.get_bool_details('always.true')
    assert_equal true, details.value
    assert_equal Details::REASON_STATIC, details.reason
  ensure
    client&.stop
  end

  # ---- TARGETING_MATCH reason ----------------------------------------

  def test_targeting_match_reason_via_integration_fixture
    client = fixture_client
    details = client.get_bool_details('of.targeting', context: { 'user' => { 'plan' => 'pro' } })
    assert_equal true, details.value
    assert_equal Details::REASON_TARGETING_MATCH, details.reason
  ensure
    client&.stop
  end

  def test_targeting_match_falls_through_to_default_branch_still_targeting
    # The of.targeting fixture has a property-match rule + an ALWAYS_TRUE
    # fallback. Even when the fallback wins, the *config* has targeting rules,
    # so wire_reason / of_reason returns TARGETING_MATCH.
    client = fixture_client
    details = client.get_bool_details('of.targeting', context: { 'user' => { 'plan' => 'free' } })
    assert_equal false, details.value
    assert_equal Details::REASON_TARGETING_MATCH, details.reason
  ensure
    client&.stop
  end

  # ---- SPLIT reason ---------------------------------------------------

  def test_split_reason_via_integration_fixture
    client = fixture_client
    # Pick a deterministic targetingKey so the outcome is reproducible.
    details = client.get_string_details('of.weighted', context: { 'user' => { 'id' => 'user-123' } })
    assert_equal Details::REASON_SPLIT, details.reason
    assert_includes %w[variant-a variant-b], details.value
  ensure
    client&.stop
  end

  # ---- DEFAULT reason -------------------------------------------------

  def test_default_reason_when_no_rule_matches
    # Config exists but no rule matches against the empty context.
    config = {
      'id' => '9',
      'key' => 'no.match.here',
      'type' => 'config',
      'valueType' => 'string',
      'sendToClientSdk' => false,
      'default' => {
        'rules' => [
          {
            'criteria' => [
              {
                'propertyName' => 'user.plan',
                'operator' => 'PROP_IS_ONE_OF',
                'valueToMatch' => { 'type' => 'string_list', 'value' => ['enterprise'] }
              }
            ],
            'value' => { 'type' => 'string', 'value' => 'gold' }
          }
        ]
      },
      'environment' => nil
    }
    store = Quonfig::ConfigStore.new
    store.set('no.match.here', config)
    client = Quonfig::Client.new(Quonfig::Options.new, store: store)

    details = client.get_string_details('no.match.here')
    assert_nil details.value
    assert_equal Details::REASON_DEFAULT, details.reason
    assert_nil details.error_code
  end

  # ---- ERROR / FLAG_NOT_FOUND ----------------------------------------

  def test_flag_not_found_returns_error_details
    client = Quonfig::Client.new(Quonfig::Options.new, store: Quonfig::ConfigStore.new)
    details = client.get_bool_details('does.not.exist')
    assert_nil details.value
    assert_equal Details::REASON_ERROR, details.reason
    assert_equal Details::ERROR_FLAG_NOT_FOUND, details.error_code
    refute_nil details.error_message
  end

  def test_flag_not_found_for_string_details
    client = Quonfig::Client.new(Quonfig::Options.new, store: Quonfig::ConfigStore.new)
    details = client.get_string_details('nope')
    assert_equal Details::REASON_ERROR, details.reason
    assert_equal Details::ERROR_FLAG_NOT_FOUND, details.error_code
  end

  # ---- ERROR / TYPE_MISMATCH -----------------------------------------

  def test_type_mismatch_for_int_when_value_is_string
    client = static_client(key: 'wrong.type', value: 'oops', type: 'string')
    details = client.get_int_details('wrong.type')
    assert_nil details.value
    assert_equal Details::REASON_ERROR, details.reason
    assert_equal Details::ERROR_TYPE_MISMATCH, details.error_code
    refute_nil details.error_message
  end

  def test_type_mismatch_for_bool_when_value_is_string
    client = static_client(key: 'bool.miss', value: 'true', type: 'string')
    details = client.get_bool_details('bool.miss')
    assert_equal Details::REASON_ERROR, details.reason
    assert_equal Details::ERROR_TYPE_MISMATCH, details.error_code
  end

  def test_type_mismatch_for_string_list_when_value_is_string
    client = static_client(key: 'list.miss', value: 'a,b', type: 'string')
    details = client.get_string_list_details('list.miss')
    assert_equal Details::REASON_ERROR, details.reason
    assert_equal Details::ERROR_TYPE_MISMATCH, details.error_code
  end

  # ---- json passes through unchanged ---------------------------------

  def test_get_json_details_returns_hash_with_static_reason
    payload = { 'a' => 1, 'b' => [1, 2] }
    client = static_client(key: 'shape', value: payload, type: 'json')
    details = client.get_json_details('shape')
    assert_equal payload, details.value
    assert_equal Details::REASON_STATIC, details.reason
  end

  # ---- Float / Int success path -------------------------------------

  def test_get_int_details_static_reason
    client = static_client(key: 'i', value: 42, type: 'int')
    details = client.get_int_details('i')
    assert_equal 42, details.value
    assert_equal Details::REASON_STATIC, details.reason
  end

  def test_get_float_details_static_reason
    client = static_client(key: 'f', value: 3.14, type: 'double')
    details = client.get_float_details('f')
    assert_in_delta 3.14, details.value, 1e-9
    assert_equal Details::REASON_STATIC, details.reason
  end

  def test_get_string_list_details_static_reason
    client = static_client(key: 'sl', value: %w[a b], type: 'string_list')
    details = client.get_string_list_details('sl')
    assert_equal %w[a b], details.value
    assert_equal Details::REASON_STATIC, details.reason
  end

  # ---- BoundClient mirror --------------------------------------------

  def test_bound_client_get_bool_details_passes_context
    client = fixture_client
    bound = client.in_context('user' => { 'plan' => 'pro' })
    details = bound.get_bool_details('of.targeting')
    assert_equal true, details.value
    assert_equal Details::REASON_TARGETING_MATCH, details.reason
  ensure
    client&.stop
  end
end
