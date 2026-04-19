# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require 'quonfig/types'

class TestTypes < Minitest::Test
  def test_value_holds_type_and_value
    v = Quonfig::Value.new(type: 'double', value: '9.95')
    assert_equal 'double', v.type
    assert_equal '9.95', v.value
    assert_nil v.confidential
    assert_nil v.decrypt_with
  end

  def test_criterion_fields_accept_nil
    c = Quonfig::Criterion.new(operator: 'ALWAYS_TRUE')
    assert_equal 'ALWAYS_TRUE', c.operator
    assert_nil c.property_name
    assert_nil c.value_to_match
  end

  def test_rule_wires_criteria_and_value
    value = Quonfig::Value.new(type: 'double', value: '9.95')
    criterion = Quonfig::Criterion.new(operator: 'ALWAYS_TRUE')
    rule = Quonfig::Rule.new(criteria: [criterion], value: value)
    assert_equal [criterion], rule.criteria
    assert_same value, rule.value
  end

  def test_rule_set_holds_rules_array
    rs = Quonfig::RuleSet.new(rules: [])
    assert_equal [], rs.rules
  end

  def test_environment_holds_id_and_rules
    env = Quonfig::Environment.new(id: 'env-1', rules: [])
    assert_equal 'env-1', env.id
    assert_equal [], env.rules
  end

  def test_meta_optional_workspace_id
    meta = Quonfig::Meta.new(version: '1', environment: 'production')
    assert_nil meta.workspace_id
  end

  def test_weighted_value_and_weighted_values_data
    wv = Quonfig::WeightedValue.new(weight: 100, value: Quonfig::Value.new(type: 'bool', value: true))
    assert_equal 100, wv.weight
    wvd = Quonfig::WeightedValuesData.new(weighted_values: [wv])
    assert_equal [wv], wvd.weighted_values
    assert_nil wvd.hash_by_property_name
  end

  def test_schema_data
    sd = Quonfig::SchemaData.new(schema_type: 'zod', schema: 'z.string()')
    assert_equal 'zod', sd.schema_type
    assert_equal 'z.string()', sd.schema
  end

  def test_provided_data
    pd = Quonfig::ProvidedData.new(source: 'ENV_VAR', lookup: 'DATABASE_URL')
    assert_equal 'ENV_VAR', pd.source
    assert_equal 'DATABASE_URL', pd.lookup
  end

  def test_config_response_from_integration_fixture
    path = File.expand_path(
      '../../integration-test-data/data/integration-tests/configs/my-double-key.json',
      __dir__
    )
    skip "integration-test-data not present at #{path}" unless File.exist?(path)

    raw = JSON.parse(File.read(path))
    default_rules = raw.fetch('default').fetch('rules').map do |rule|
      criteria = rule.fetch('criteria').map do |c|
        Quonfig::Criterion.new(
          property_name: c['propertyName'],
          operator: c.fetch('operator'),
          value_to_match: c['valueToMatch']
        )
      end
      value = rule.fetch('value')
      Quonfig::Rule.new(
        criteria: criteria,
        value: Quonfig::Value.new(type: value['type'], value: value['value'])
      )
    end

    response = Quonfig::ConfigResponse.new(
      id: raw.fetch('id'),
      key: raw.fetch('key'),
      type: raw.fetch('type'),
      value_type: raw.fetch('valueType'),
      send_to_client_sdk: raw.fetch('sendToClientSdk'),
      default: Quonfig::RuleSet.new(rules: default_rules)
    )

    assert_equal 'my-double-key', response.key
    assert_equal 'config', response.type
    assert_equal 'double', response.value_type
    refute response.send_to_client_sdk
    assert_nil response.environment
    assert_equal 1, response.default.rules.length

    rule = response.default.rules.first
    assert_equal 'ALWAYS_TRUE', rule.criteria.first.operator
    assert_equal 'double', rule.value.type
    assert_equal '9.95', rule.value.value
  end

  def test_config_envelope_carries_configs_and_meta
    meta = Quonfig::Meta.new(version: '1', environment: 'production')
    envelope = Quonfig::ConfigEnvelope.new(configs: [], meta: meta)
    assert_equal [], envelope.configs
    assert_same meta, envelope.meta
  end

  def test_workspace_config_document_fields
    doc = Quonfig::WorkspaceConfigDocument.new(
      id: 'id-1',
      key: 'feature.x',
      type: 'feature_flag',
      value_type: 'bool',
      send_to_client_sdk: true,
      default: Quonfig::RuleSet.new(rules: []),
      environments: []
    )
    assert_equal 'feature.x', doc.key
    assert_equal 'feature_flag', doc.type
    assert_equal 'bool', doc.value_type
    assert doc.send_to_client_sdk
    assert_equal [], doc.environments
  end

  def test_workspace_environment_fields
    we = Quonfig::WorkspaceEnvironment.new(id: 'env-1', rules: [])
    assert_equal 'env-1', we.id
    assert_equal [], we.rules
  end
end
