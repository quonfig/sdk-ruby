# frozen_string_literal: true

# AUTO-GENERATED from integration-test-data/tests/eval/context_precedence.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestContextPrecedence < Minitest::Test
  # returns the correct `flag` value using the global context (1)
  def test_returns_the_correct_flag_value_using_the_global_context_1
    client = IntegrationTestHelpers.build_client(global_context: { 'user' => { 'isHuman' => 'verified' } })
    actual = client.enabled?('mixed.case.property.name')
    assert_equal true, actual, 'client.enabled?(mixed.case.property.name)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns the correct `flag` value using the global context (2)
  def test_returns_the_correct_flag_value_using_the_global_context_2
    client = IntegrationTestHelpers.build_client(global_context: { 'user' => { 'isHuman' => '?' } })
    actual = client.enabled?('mixed.case.property.name')
    assert_equal false, actual, 'client.enabled?(mixed.case.property.name)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns the correct `flag` value when local context clobbers global context (1)
  def test_returns_the_correct_flag_value_when_local_context_clobbers_global_context_1
    client = IntegrationTestHelpers.build_client(global_context: { 'user' => { 'isHuman' => '?' } })
    actual = client.enabled?('mixed.case.property.name', { 'user' => { 'isHuman' => 'verified' } })
    assert_equal true, actual, 'client.enabled?(mixed.case.property.name, { user => { isHuman => verified } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns the correct `flag` value when local context clobbers global context (2)
  def test_returns_the_correct_flag_value_when_local_context_clobbers_global_context_2
    client = IntegrationTestHelpers.build_client(global_context: { 'user' => { 'isHuman' => 'verified' } })
    actual = client.enabled?('mixed.case.property.name', { 'user' => { 'isHuman' => '?' } })
    assert_equal false, actual, 'client.enabled?(mixed.case.property.name, { user => { isHuman => ? } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns the correct `flag` value when block context clobbers global context (1)
  def test_returns_the_correct_flag_value_when_block_context_clobbers_global_context_1
    client = IntegrationTestHelpers.build_client(global_context: { 'user' => { 'isHuman' => 'verified' } })
    scope = client.with_context({ 'user' => { 'isHuman' => '?' } })
    actual = scope.enabled?('mixed.case.property.name')
    assert_equal false, actual, 'scope.enabled?(mixed.case.property.name)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns the correct `flag` value when block context clobbers global context (2)
  def test_returns_the_correct_flag_value_when_block_context_clobbers_global_context_2
    client = IntegrationTestHelpers.build_client(global_context: { 'user' => { 'isHuman' => '?' } })
    scope = client.with_context({ 'user' => { 'isHuman' => 'verified' } })
    actual = scope.enabled?('mixed.case.property.name')
    assert_equal true, actual, 'scope.enabled?(mixed.case.property.name)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns the correct `flag` value when local context clobbers block context (1)
  def test_returns_the_correct_flag_value_when_local_context_clobbers_block_context_1
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'isHuman' => 'verified' } })
    scope = scope.in_context({ 'user' => { 'isHuman' => '?' } })
    actual = scope.enabled?('mixed.case.property.name')
    assert_equal false, actual, 'scope.enabled?(mixed.case.property.name)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns the correct `flag` value when local context clobbers block context (2)
  def test_returns_the_correct_flag_value_when_local_context_clobbers_block_context_2
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'isHuman' => '?' } })
    scope = scope.in_context({ 'user' => { 'isHuman' => 'verified' } })
    actual = scope.enabled?('mixed.case.property.name')
    assert_equal true, actual, 'scope.enabled?(mixed.case.property.name)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns the correct `get` value using the global context (1)
  def test_returns_the_correct_get_value_using_the_global_context_1
    client = IntegrationTestHelpers.build_client(global_context: { 'user' => { 'email' => 'test@prefab.cloud' } })
    actual = client.get_string('basic.rule.config')
    assert_equal 'override', actual, 'client.get_string(basic.rule.config)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns the correct `get` value using the global context (2)
  def test_returns_the_correct_get_value_using_the_global_context_2
    client = IntegrationTestHelpers.build_client(global_context: { 'user' => { 'email' => 'test@example.com' } })
    actual = client.get_string('basic.rule.config')
    assert_equal 'default', actual, 'client.get_string(basic.rule.config)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns the correct `get` value when local context clobbers global context (1)
  def test_returns_the_correct_get_value_when_local_context_clobbers_global_context_1
    client = IntegrationTestHelpers.build_client(global_context: { 'user' => { 'email' => 'test@example.com' } })
    actual = client.get_string('basic.rule.config', context: { 'user' => { 'email' => 'test@prefab.cloud' } })
    assert_equal 'override', actual, 'client.get_string(basic.rule.config, context: { user => { email => test@prefab.cloud } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns the correct `get` value when local context clobbers global context (2)
  def test_returns_the_correct_get_value_when_local_context_clobbers_global_context_2
    client = IntegrationTestHelpers.build_client(global_context: { 'user' => { 'email' => 'test@prefab.cloud' } })
    actual = client.get_string('basic.rule.config', context: { 'user' => { 'email' => 'test@example.com' } })
    assert_equal 'default', actual, 'client.get_string(basic.rule.config, context: { user => { email => test@example.com } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns the correct `get` value when block context clobbers global context (1)
  def test_returns_the_correct_get_value_when_block_context_clobbers_global_context_1
    client = IntegrationTestHelpers.build_client(global_context: { 'user' => { 'email' => 'test@prefab.cloud' } })
    scope = client.with_context({ 'user' => { 'email' => 'test@example.com' } })
    actual = scope.get_string('basic.rule.config')
    assert_equal 'default', actual, 'scope.get_string(basic.rule.config)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns the correct `get` value when block context clobbers global context (2)
  def test_returns_the_correct_get_value_when_block_context_clobbers_global_context_2
    client = IntegrationTestHelpers.build_client(global_context: { 'user' => { 'email' => 'test@example.com' } })
    scope = client.with_context({ 'user' => { 'email' => 'test@prefab.cloud' } })
    actual = scope.get_string('basic.rule.config')
    assert_equal 'override', actual, 'scope.get_string(basic.rule.config)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns the correct `get` value when local context clobbers block context (1)
  def test_returns_the_correct_get_value_when_local_context_clobbers_block_context_1
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'email' => 'test@prefab.cloud' } })
    scope = scope.in_context({ 'user' => { 'email' => 'test@example.com' } })
    actual = scope.get_string('basic.rule.config')
    assert_equal 'default', actual, 'scope.get_string(basic.rule.config)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns the correct `get` value when local context clobbers block context (2)
  def test_returns_the_correct_get_value_when_local_context_clobbers_block_context_2
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'email' => 'test@example.com' } })
    scope = scope.in_context({ 'user' => { 'email' => 'test@prefab.cloud' } })
    actual = scope.get_string('basic.rule.config')
    assert_equal 'override', actual, 'scope.get_string(basic.rule.config)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns the correct `get` value when local context replaces the whole global named context (disjoint attributes)
  def test_returns_the_correct_get_value_when_local_context_replaces_the_whole_global_named_context_disjoint_attributes
    client = IntegrationTestHelpers.build_client(global_context: { 'user' => { 'email' => 'test@prefab.cloud' } })
    actual = client.get_string('basic.rule.config', context: { 'user' => { 'plan' => 'pro' } })
    assert_equal 'default', actual, 'client.get_string(basic.rule.config, context: { user => { plan => pro } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns the correct `get` value when a named context the local context does not mention survives
  def test_returns_the_correct_get_value_when_a_named_context_the_local_context_does_not_mention_survives
    client = IntegrationTestHelpers.build_client(global_context: { 'user' => { 'email' => 'test@prefab.cloud' } })
    actual = client.get_string('basic.rule.config', context: { 'team' => { 'plan' => 'pro' } })
    assert_equal 'override', actual, 'client.get_string(basic.rule.config, context: { team => { plan => pro } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end
end
