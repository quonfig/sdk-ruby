# frozen_string_literal: true

# AUTO-GENERATED from integration-test-data/tests/eval/enabled_with_contexts.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestEnabledWithContexts < Minitest::Test
  # returns true from global context
  def test_returns_true_from_global_context
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ '' => { 'domain' => 'prefab.cloud' }, 'user' => { 'key' => 'michael' } })
    actual = scope.enabled?('feature-flag.in-seg.segment-and')
    assert_equal true, actual, 'scope.enabled?(feature-flag.in-seg.segment-and)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false due to local context override
  def test_returns_false_due_to_local_context_override
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ '' => { 'domain' => 'prefab.cloud' }, 'user' => { 'key' => 'michael' } })
    scope = scope.in_context({ 'user' => { 'key' => 'james' } })
    actual = scope.enabled?('feature-flag.in-seg.segment-and')
    assert_equal false, actual, 'scope.enabled?(feature-flag.in-seg.segment-and)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for untouched scope context
  def test_returns_false_for_untouched_scope_context
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ '' => { 'domain' => 'example.com' }, 'user' => { 'key' => 'nobody' } })
    actual = scope.enabled?('feature-flag.in-seg.segment-and')
    assert_equal false, actual, 'scope.enabled?(feature-flag.in-seg.segment-and)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false due to partial scope context override of user.key
  def test_returns_false_due_to_partial_scope_context_override_of_user_key
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ '' => { 'domain' => 'example.com' }, 'user' => { 'key' => 'nobody' } })
    scope = scope.in_context({ 'user' => { 'key' => 'michael' } })
    actual = scope.enabled?('feature-flag.in-seg.segment-and')
    assert_equal false, actual, 'scope.enabled?(feature-flag.in-seg.segment-and)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false due to partial scope context override of domain
  def test_returns_false_due_to_partial_scope_context_override_of_domain
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ '' => { 'domain' => 'example.com' }, 'user' => { 'key' => 'nobody' } })
    scope = scope.in_context({ '' => { 'domain' => 'prefab.cloud' } })
    actual = scope.enabled?('feature-flag.in-seg.segment-and')
    assert_equal false, actual, 'scope.enabled?(feature-flag.in-seg.segment-and)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true due to local override of domain when scope user.key already matches
  def test_returns_true_due_to_local_override_of_domain_when_scope_user_key_already_matches
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ '' => { 'domain' => 'example.com' }, 'user' => { 'key' => 'michael' } })
    scope = scope.in_context({ '' => { 'domain' => 'prefab.cloud' } })
    actual = scope.enabled?('feature-flag.in-seg.segment-and')
    assert_equal true, actual, 'scope.enabled?(feature-flag.in-seg.segment-and)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true due to full scope context override of user.key and domain
  def test_returns_true_due_to_full_scope_context_override_of_user_key_and_domain
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ '' => { 'domain' => 'example.com' }, 'user' => { 'key' => 'nobody' } })
    scope = scope.in_context({ 'user' => { 'key' => 'michael' }, '' => { 'domain' => 'prefab.cloud' } })
    actual = scope.enabled?('feature-flag.in-seg.segment-and')
    assert_equal true, actual, 'scope.enabled?(feature-flag.in-seg.segment-and)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for rule with different case on context property name
  def test_returns_false_for_rule_with_different_case_on_context_property_name
    client = IntegrationTestHelpers.build_client
    actual = client.enabled?('mixed.case.property.name', { 'user' => { 'IsHuman' => 'verified' } })
    assert_equal false, actual, 'client.enabled?(mixed.case.property.name, { user => { IsHuman => verified } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for matching case on context property name
  def test_returns_true_for_matching_case_on_context_property_name
    client = IntegrationTestHelpers.build_client
    actual = client.enabled?('mixed.case.property.name', { 'user' => { 'isHuman' => 'verified' } })
    assert_equal true, actual, 'client.enabled?(mixed.case.property.name, { user => { isHuman => verified } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end
end
