# frozen_string_literal: true
#
# AUTO-GENERATED from integration-test-data/tests/eval/telemetry.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestTelemetry < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store("telemetry")
  end

  # reason is STATIC for config with no targeting rules
  def test_reason_is_static_for_config_with_no_targeting_rules
    aggregator = IntegrationTestHelpers.build_aggregator(:evaluation_summary, {})
    IntegrationTestHelpers.feed_aggregator(aggregator, :evaluation_summary, {"keys" => ["brand.new.string"]}, contexts: {})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :evaluation_summary, [{"key" => "brand.new.string", "type" => "CONFIG", "value" => "hello.world", "value_type" => "string", "count" => 1, "reason" => 1, "summary" => {"config_row_index" => 0, "conditional_value_index" => 0}}], endpoint: "/api/v1/telemetry")
  end

  # reason is STATIC for feature flag with only ALWAYS_TRUE rules
  def test_reason_is_static_for_feature_flag_with_only_always_true_rules
    aggregator = IntegrationTestHelpers.build_aggregator(:evaluation_summary, {})
    IntegrationTestHelpers.feed_aggregator(aggregator, :evaluation_summary, {"keys" => ["always.true"]}, contexts: {})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :evaluation_summary, [{"key" => "always.true", "type" => "FEATURE_FLAG", "value" => true, "value_type" => "bool", "count" => 1, "reason" => 1, "summary" => {"config_row_index" => 0, "conditional_value_index" => 0}}], endpoint: "/api/v1/telemetry")
  end

  # reason is TARGETING_MATCH when config has targeting rules but evaluation falls through
  def test_reason_is_targeting_match_when_config_has_targeting_rules_but_evaluation_falls_through
    aggregator = IntegrationTestHelpers.build_aggregator(:evaluation_summary, {})
    IntegrationTestHelpers.feed_aggregator(aggregator, :evaluation_summary, {"keys" => ["my-test-key"]}, contexts: {})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :evaluation_summary, [{"key" => "my-test-key", "type" => "CONFIG", "value" => "my-test-value", "value_type" => "string", "count" => 1, "reason" => 2, "summary" => {"config_row_index" => 0, "conditional_value_index" => 1}}], endpoint: "/api/v1/telemetry")
  end

  # reason is TARGETING_MATCH when a targeting rule matches
  def test_reason_is_targeting_match_when_a_targeting_rule_matches
    aggregator = IntegrationTestHelpers.build_aggregator(:evaluation_summary, {})
    IntegrationTestHelpers.feed_aggregator(aggregator, :evaluation_summary, {"keys" => ["feature-flag.integer"]}, contexts: {"user" => {"key" => "michael"}})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :evaluation_summary, [{"key" => "feature-flag.integer", "type" => "FEATURE_FLAG", "value" => 5, "value_type" => "int", "count" => 1, "reason" => 2, "summary" => {"config_row_index" => 0, "conditional_value_index" => 0}}], endpoint: "/api/v1/telemetry")
  end

  # reason is SPLIT for weighted value evaluation
  def test_reason_is_split_for_weighted_value_evaluation
    aggregator = IntegrationTestHelpers.build_aggregator(:evaluation_summary, {})
    IntegrationTestHelpers.feed_aggregator(aggregator, :evaluation_summary, {"keys" => ["feature-flag.weighted"]}, contexts: {"user" => {"tracking_id" => "92a202f2"}})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :evaluation_summary, [{"key" => "feature-flag.weighted", "type" => "FEATURE_FLAG", "value" => 2, "value_type" => "int", "count" => 1, "reason" => 3, "summary" => {"config_row_index" => 0, "conditional_value_index" => 0, "weighted_value_index" => 2}}], endpoint: "/api/v1/telemetry")
  end

  # reason is TARGETING_MATCH for feature flag fallthrough with targeting rules
  def test_reason_is_targeting_match_for_feature_flag_fallthrough_with_targeting_rules
    aggregator = IntegrationTestHelpers.build_aggregator(:evaluation_summary, {})
    IntegrationTestHelpers.feed_aggregator(aggregator, :evaluation_summary, {"keys" => ["feature-flag.integer"]}, contexts: {})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :evaluation_summary, [{"key" => "feature-flag.integer", "type" => "FEATURE_FLAG", "value" => 3, "value_type" => "int", "count" => 1, "reason" => 2, "summary" => {"config_row_index" => 0, "conditional_value_index" => 1}}], endpoint: "/api/v1/telemetry")
  end

  # evaluation summary deduplicates identical evaluations
  def test_evaluation_summary_deduplicates_identical_evaluations
    aggregator = IntegrationTestHelpers.build_aggregator(:evaluation_summary, {})
    IntegrationTestHelpers.feed_aggregator(aggregator, :evaluation_summary, {"keys" => ["brand.new.string", "brand.new.string", "brand.new.string", "brand.new.string", "brand.new.string"]}, contexts: {})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :evaluation_summary, [{"key" => "brand.new.string", "type" => "CONFIG", "value" => "hello.world", "value_type" => "string", "count" => 5, "reason" => 1, "summary" => {"config_row_index" => 0, "conditional_value_index" => 0}}], endpoint: "/api/v1/telemetry")
  end

  # evaluation summary creates separate counters for different rules of same config
  def test_evaluation_summary_creates_separate_counters_for_different_rules_of_same_config
    aggregator = IntegrationTestHelpers.build_aggregator(:evaluation_summary, {})
    IntegrationTestHelpers.feed_aggregator(aggregator, :evaluation_summary, {"keys" => ["feature-flag.integer"], "keys_without_context" => ["feature-flag.integer"]}, contexts: {"user" => {"key" => "michael"}})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :evaluation_summary, [{"key" => "feature-flag.integer", "type" => "FEATURE_FLAG", "value" => 5, "value_type" => "int", "count" => 1, "reason" => 2, "summary" => {"config_row_index" => 0, "conditional_value_index" => 0}}, {"key" => "feature-flag.integer", "type" => "FEATURE_FLAG", "value" => 3, "value_type" => "int", "count" => 1, "reason" => 2, "summary" => {"config_row_index" => 0, "conditional_value_index" => 1}}], endpoint: "/api/v1/telemetry")
  end

  # evaluation summary groups by config key
  def test_evaluation_summary_groups_by_config_key
    aggregator = IntegrationTestHelpers.build_aggregator(:evaluation_summary, {})
    IntegrationTestHelpers.feed_aggregator(aggregator, :evaluation_summary, {"keys" => ["brand.new.string", "always.true"]}, contexts: {})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :evaluation_summary, [{"key" => "brand.new.string", "type" => "CONFIG", "value" => "hello.world", "value_type" => "string", "count" => 1, "reason" => 1, "summary" => {"config_row_index" => 0, "conditional_value_index" => 0}}, {"key" => "always.true", "type" => "FEATURE_FLAG", "value" => true, "value_type" => "bool", "count" => 1, "reason" => 1, "summary" => {"config_row_index" => 0, "conditional_value_index" => 0}}], endpoint: "/api/v1/telemetry")
  end

  # selectedValue wraps string correctly
  def test_selectedvalue_wraps_string_correctly
    aggregator = IntegrationTestHelpers.build_aggregator(:evaluation_summary, {})
    IntegrationTestHelpers.feed_aggregator(aggregator, :evaluation_summary, {"keys" => ["brand.new.string"]}, contexts: {})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :evaluation_summary, [{"key" => "brand.new.string", "type" => "CONFIG", "value" => "hello.world", "value_type" => "string", "count" => 1, "reason" => 1, "selected_value" => {"string" => "hello.world"}, "summary" => {"config_row_index" => 0, "conditional_value_index" => 0}}], endpoint: "/api/v1/telemetry")
  end

  # selectedValue wraps boolean correctly
  def test_selectedvalue_wraps_boolean_correctly
    aggregator = IntegrationTestHelpers.build_aggregator(:evaluation_summary, {})
    IntegrationTestHelpers.feed_aggregator(aggregator, :evaluation_summary, {"keys" => ["brand.new.boolean"]}, contexts: {})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :evaluation_summary, [{"key" => "brand.new.boolean", "type" => "CONFIG", "value" => false, "value_type" => "bool", "count" => 1, "reason" => 1, "selected_value" => {"bool" => false}, "summary" => {"config_row_index" => 0, "conditional_value_index" => 0}}], endpoint: "/api/v1/telemetry")
  end

  # selectedValue wraps int correctly
  def test_selectedvalue_wraps_int_correctly
    aggregator = IntegrationTestHelpers.build_aggregator(:evaluation_summary, {})
    IntegrationTestHelpers.feed_aggregator(aggregator, :evaluation_summary, {"keys" => ["brand.new.int"]}, contexts: {})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :evaluation_summary, [{"key" => "brand.new.int", "type" => "CONFIG", "value" => 123, "value_type" => "int", "count" => 1, "reason" => 1, "selected_value" => {"int" => 123}, "summary" => {"config_row_index" => 0, "conditional_value_index" => 0}}], endpoint: "/api/v1/telemetry")
  end

  # selectedValue wraps double correctly
  def test_selectedvalue_wraps_double_correctly
    aggregator = IntegrationTestHelpers.build_aggregator(:evaluation_summary, {})
    IntegrationTestHelpers.feed_aggregator(aggregator, :evaluation_summary, {"keys" => ["brand.new.double"]}, contexts: {})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :evaluation_summary, [{"key" => "brand.new.double", "type" => "CONFIG", "value" => 123.99, "value_type" => "double", "count" => 1, "reason" => 1, "selected_value" => {"double" => 123.99}, "summary" => {"config_row_index" => 0, "conditional_value_index" => 0}}], endpoint: "/api/v1/telemetry")
  end

  # selectedValue wraps string list correctly
  def test_selectedvalue_wraps_string_list_correctly
    aggregator = IntegrationTestHelpers.build_aggregator(:evaluation_summary, {})
    IntegrationTestHelpers.feed_aggregator(aggregator, :evaluation_summary, {"keys" => ["my-string-list-key"]}, contexts: {})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :evaluation_summary, [{"key" => "my-string-list-key", "type" => "CONFIG", "value" => ["a", "b", "c"], "value_type" => "string_list", "count" => 1, "reason" => 1, "selected_value" => {"stringList" => ["a", "b", "c"]}, "summary" => {"config_row_index" => 0, "conditional_value_index" => 0}}], endpoint: "/api/v1/telemetry")
  end

  # context shape merges fields across multiple records
  def test_context_shape_merges_fields_across_multiple_records
    aggregator = IntegrationTestHelpers.build_aggregator(:context_shape, {})
    IntegrationTestHelpers.feed_aggregator(aggregator, :context_shape, [{"user" => {"name" => "alice", "age" => 30}}, {"user" => {"name" => "bob", "score" => 9.5}, "team" => {"name" => "engineering"}}], contexts: {})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :context_shape, [{"name" => "user", "field_types" => {"name" => 2, "age" => 1, "score" => 4}}, {"name" => "team", "field_types" => {"name" => 2}}], endpoint: "/api/v1/context-shapes")
  end

  # example contexts deduplicates by key value
  def test_example_contexts_deduplicates_by_key_value
    aggregator = IntegrationTestHelpers.build_aggregator(:example_contexts, {})
    IntegrationTestHelpers.feed_aggregator(aggregator, :example_contexts, [{"user" => {"key" => "user-123", "name" => "alice"}}, {"user" => {"key" => "user-123", "name" => "bob"}}], contexts: {})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :example_contexts, {"user" => {"key" => "user-123", "name" => "alice"}}, endpoint: "/api/v1/telemetry")
  end

  # telemetry disabled emits nothing
  def test_telemetry_disabled_emits_nothing
    aggregator = IntegrationTestHelpers.build_aggregator(:evaluation_summary, {"collect_evaluation_summaries" => false, "context_upload_mode" => ":none"})
    IntegrationTestHelpers.feed_aggregator(aggregator, :evaluation_summary, {"keys" => ["brand.new.string"]}, contexts: {})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :evaluation_summary, nil, endpoint: "/api/v1/telemetry")
  end

  # shapes only mode reports shapes but not examples
  def test_shapes_only_mode_reports_shapes_but_not_examples
    aggregator = IntegrationTestHelpers.build_aggregator(:context_shape, {"context_upload_mode" => ":shape_only"})
    IntegrationTestHelpers.feed_aggregator(aggregator, :context_shape, {"user" => {"name" => "alice", "key" => "alice-123"}}, contexts: {})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :context_shape, [{"name" => "user", "field_types" => {"name" => 2, "key" => 2}}], endpoint: "/api/v1/context-shapes")
  end

  # log level evaluations are excluded from telemetry
  def test_log_level_evaluations_are_excluded_from_telemetry
    aggregator = IntegrationTestHelpers.build_aggregator(:evaluation_summary, {})
    IntegrationTestHelpers.feed_aggregator(aggregator, :evaluation_summary, {"keys" => ["log-level.prefab.criteria_evaluator"]}, contexts: {})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :evaluation_summary, nil, endpoint: "/api/v1/telemetry")
  end

  # empty context produces no context telemetry
  def test_empty_context_produces_no_context_telemetry
    aggregator = IntegrationTestHelpers.build_aggregator(:context_shape, {})
    IntegrationTestHelpers.feed_aggregator(aggregator, :context_shape, {}, contexts: {})
    IntegrationTestHelpers.assert_aggregator_post(aggregator, :context_shape, nil, endpoint: "/api/v1/context-shapes")
  end
end
