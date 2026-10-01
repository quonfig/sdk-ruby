# frozen_string_literal: true

# AUTO-GENERATED from integration-test-data/tests/eval/get_feature_flag.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestGetFeatureFlag < Minitest::Test
  # get returns the underlying value for a feature flag
  def test_get_returns_the_underlying_value_for_a_feature_flag
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('feature-flag.integer')
    assert_equal 3, actual, 'client.get_int(feature-flag.integer)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # get returns the underlying value for a feature flag that matches the highest precedent rule
  def test_get_returns_the_underlying_value_for_a_feature_flag_that_matches_the_highest_precedent_rule
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('feature-flag.integer', context: { 'user' => { 'key' => 'michael' } })
    assert_equal 5, actual, 'client.get_int(feature-flag.integer, context: { user => { key => michael } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end
end
