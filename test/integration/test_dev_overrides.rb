# frozen_string_literal: true

# AUTO-GENERATED from integration-test-data/tests/eval/dev_overrides.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestDevOverrides < Minitest::Test
  # override fires when quonfig-user.email matches
  def test_override_fires_when_quonfig_user_email_matches
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'quonfig-user' => { 'email' => 'bob@foo.com' } })
    actual = scope.enabled?('feature-flag.dev-override')
    assert_equal true, actual, 'scope.enabled?(feature-flag.dev-override)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # override does not fire when attribute absent (prod simulation)
  def test_override_does_not_fire_when_attribute_absent_prod_simulation
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'email' => 'bob@foo.com' } })
    actual = scope.enabled?('feature-flag.dev-override')
    assert_equal false, actual, 'scope.enabled?(feature-flag.dev-override)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # override matches any email in IS_ONE_OF list
  def test_override_matches_any_email_in_is_one_of_list
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'quonfig-user' => { 'email' => 'alice@foo.com' } })
    actual = scope.enabled?('feature-flag.dev-override.multi-email')
    assert_equal true, actual, 'scope.enabled?(feature-flag.dev-override.multi-email)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # override beats customer rule by priority
  def test_override_beats_customer_rule_by_priority
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'quonfig-user' => { 'email' => 'bob@foo.com' }, 'user' => { 'country' => 'DE' } })
    actual = scope.enabled?('feature-flag.dev-override.priority')
    assert_equal true, actual, 'scope.enabled?(feature-flag.dev-override.priority)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end
end
