# frozen_string_literal: true
#
# AUTO-GENERATED from integration-test-data/tests/eval/post.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestPost < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store("post")
  end

  # reports context shape aggregation
  def test_reports_context_shape_aggregation
    aggregator = IntegrationTestHelpers.build_aggregator(:context_shape, {"context_upload_mode" => ":shape_only"})
    IntegrationTestHelpers.feed_aggregator(aggregator, :context_shape, {"user" => {"name" => "Michael", "age" => 38, "human" => true}, "role" => {"name" => "developer", "admin" => false, "salary" => 15.75, "permissions" => ["read", "write"]}}, contexts: {})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :context_shape, [{"name" => "user", "field_types" => {"name" => 2, "age" => 1, "human" => 5}}, {"name" => "role", "field_types" => {"name" => 2, "admin" => 5, "salary" => 4, "permissions" => 10}}], endpoint: "/api/v1/context-shapes")
  end

  # reports evaluation summary
  def test_reports_evaluation_summary
    aggregator = IntegrationTestHelpers.build_aggregator(:evaluation_summary, {})
    IntegrationTestHelpers.feed_aggregator(aggregator, :evaluation_summary, {"keys" => ["my-test-key", "feature-flag.integer", "my-string-list-key", "feature-flag.integer", "feature-flag.weighted"]}, contexts: {"user" => {"tracking_id" => "92a202f2"}})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :evaluation_summary, [{"key" => "my-test-key", "type" => "CONFIG", "value" => "my-test-value", "value_type" => "string", "count" => 1, "reason" => 2, "summary" => {"config_row_index" => 0, "conditional_value_index" => 1}}, {"key" => "my-string-list-key", "type" => "CONFIG", "value" => ["a", "b", "c"], "value_type" => "string_list", "count" => 1, "reason" => 1, "summary" => {"config_row_index" => 0, "conditional_value_index" => 0}}, {"key" => "feature-flag.integer", "type" => "FEATURE_FLAG", "value" => 3, "value_type" => "int", "count" => 2, "reason" => 2, "summary" => {"config_row_index" => 0, "conditional_value_index" => 1}}, {"key" => "feature-flag.weighted", "type" => "FEATURE_FLAG", "value" => 2, "value_type" => "int", "count" => 1, "reason" => 3, "summary" => {"config_row_index" => 0, "conditional_value_index" => 0, "weighted_value_index" => 2}}], endpoint: "/api/v1/telemetry")
  end

  # reports example contexts
  def test_reports_example_contexts
    aggregator = IntegrationTestHelpers.build_aggregator(:example_contexts, {})
    IntegrationTestHelpers.feed_aggregator(aggregator, :example_contexts, {"user" => {"name" => "michael", "age" => 38, "key" => "michael:1234"}, "device" => {"mobile" => false}, "team" => {"id" => 3.5}}, contexts: {})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :example_contexts, {"user" => {"name" => "michael", "age" => 38, "key" => "michael:1234"}, "device" => {"mobile" => false}, "team" => {"id" => 3.5}}, endpoint: "/api/v1/telemetry")
  end

  # example contexts without key are not reported
  def test_example_contexts_without_key_are_not_reported
    aggregator = IntegrationTestHelpers.build_aggregator(:example_contexts, {})
    IntegrationTestHelpers.feed_aggregator(aggregator, :example_contexts, {"user" => {"name" => "michael", "age" => 38}, "device" => {"mobile" => false}, "team" => {"id" => 3.5}}, contexts: {})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :example_contexts, nil, endpoint: "/api/v1/telemetry")
  end
end
