# frozen_string_literal: true
#
# AUTO-GENERATED from integration-test-data/tests/eval/get_weighted_values.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestGetWeightedValues < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store("get_weighted_values")
  end

  # weighted value is consistent 1
  def test_weighted_value_is_consistent_1
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "feature-flag.weighted", {"user" => {"tracking_id" => "a72c15f5"}}, 1)
  end

  # weighted value is consistent 2
  def test_weighted_value_is_consistent_2
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "feature-flag.weighted", {"user" => {"tracking_id" => "92a202f2"}}, 2)
  end

  # weighted value is consistent 3
  def test_weighted_value_is_consistent_3
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "feature-flag.weighted", {"user" => {"tracking_id" => "8f414100"}}, 3)
  end
end
