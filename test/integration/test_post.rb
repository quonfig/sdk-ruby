# frozen_string_literal: true
#
# AUTO-GENERATED from integration-test-data/tests/eval/post.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.
#
# OMITTED CASES (4) — generator could not express these in
# the current sdk-ruby integration helpers. Either extend
# IntegrationTestHelpers to support the shape, or remove the case from YAML:
#   - reports context shape aggregation :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - reports evaluation summary :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - reports example contexts :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers
#   - example contexts without key are not reported :: YAML shape (post/telemetry-style data/expected_data/aggregator) not yet expressible in sdk-ruby integration helpers

require 'test_helper'
require 'integration/test_helpers'

class TestPost < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store("post")
  end
end
