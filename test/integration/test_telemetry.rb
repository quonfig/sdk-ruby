# frozen_string_literal: true
#
# AUTO-GENERATED from integration-test-data/tests/eval/telemetry.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.
#
# OMITTED CASES (20) — generator could not express these in
# the current sdk-ruby integration helpers. Either extend
# IntegrationTestHelpers to support the shape, or remove the case from YAML:
#   - reason is STATIC for config with no targeting rules :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - reason is STATIC for feature flag with only ALWAYS_TRUE rules :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - reason is TARGETING_MATCH when config has targeting rules but evaluation falls through :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - reason is TARGETING_MATCH when a targeting rule matches :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - reason is SPLIT for weighted value evaluation :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - reason is TARGETING_MATCH for feature flag fallthrough with targeting rules :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - evaluation summary deduplicates identical evaluations :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - evaluation summary creates separate counters for different rules of same config :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - evaluation summary groups by config key :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - selectedValue wraps string correctly :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - selectedValue wraps boolean correctly :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - selectedValue wraps int correctly :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - selectedValue wraps double correctly :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - selectedValue wraps string list correctly :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - context shape merges fields across multiple records :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - example contexts deduplicates by key value :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - telemetry disabled emits nothing :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - shapes only mode reports shapes but not examples :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - log level evaluations are excluded from telemetry :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - empty context produces no context telemetry :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers

require 'test_helper'
require 'integration/test_helpers'

class TestTelemetry < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store("telemetry")
  end
end
