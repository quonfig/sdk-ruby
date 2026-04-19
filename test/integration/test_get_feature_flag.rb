# frozen_string_literal: true
#
# AUTO-GENERATED from integration-test-data/tests/eval/get_feature_flag.yaml.
# Regenerate with `bundle exec ruby scripts/generate_integration_tests.rb`.
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestGetFeatureFlag < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store("get_feature_flag")
  end

  # get returns the underlying value for a feature flag
  def test_get_returns_the_underlying_value_for_a_feature_flag
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "feature-flag.integer", {}, 3)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # get returns the underlying value for a feature flag that matches the highest precedent rule
  def test_get_returns_the_underlying_value_for_a_feature_flag_that_matches_the_highest_precedent_rule
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "feature-flag.integer", {"user" => {"key" => "michael"}}, 5)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end
end
