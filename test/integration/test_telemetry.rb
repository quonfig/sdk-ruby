# frozen_string_literal: true
#
# AUTO-GENERATED from integration-test-data/tests/eval/telemetry.yaml.
# Regenerate with `bundle exec ruby scripts/generate_integration_tests.rb`.
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestTelemetry < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store("telemetry")
  end

  # reason is STATIC for config with no targeting rules
  def test_reason_is_static_for_config_with_no_targeting_rules
    skip("telemetry aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # reason is STATIC for feature flag with only ALWAYS_TRUE rules
  def test_reason_is_static_for_feature_flag_with_only_always_true_rules
    skip("telemetry aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # reason is TARGETING_MATCH when config has targeting rules but evaluation falls through
  def test_reason_is_targeting_match_when_config_has_targeting_rules_but_evaluation_falls_through
    skip("telemetry aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # reason is TARGETING_MATCH when a targeting rule matches
  def test_reason_is_targeting_match_when_a_targeting_rule_matches
    skip("telemetry aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # reason is SPLIT for weighted value evaluation
  def test_reason_is_split_for_weighted_value_evaluation
    skip("telemetry aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # reason is TARGETING_MATCH for feature flag fallthrough with targeting rules
  def test_reason_is_targeting_match_for_feature_flag_fallthrough_with_targeting_rules
    skip("telemetry aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # evaluation summary deduplicates identical evaluations
  def test_evaluation_summary_deduplicates_identical_evaluations
    skip("telemetry aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # evaluation summary creates separate counters for different rules of same config
  def test_evaluation_summary_creates_separate_counters_for_different_rules_of_same_config
    skip("telemetry aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # evaluation summary groups by config key
  def test_evaluation_summary_groups_by_config_key
    skip("telemetry aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # selectedValue wraps string correctly
  def test_selectedvalue_wraps_string_correctly
    skip("telemetry aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # selectedValue wraps boolean correctly
  def test_selectedvalue_wraps_boolean_correctly
    skip("telemetry aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # selectedValue wraps int correctly
  def test_selectedvalue_wraps_int_correctly
    skip("telemetry aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # selectedValue wraps double correctly
  def test_selectedvalue_wraps_double_correctly
    skip("telemetry aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # selectedValue wraps string list correctly
  def test_selectedvalue_wraps_string_list_correctly
    skip("telemetry aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # context shape merges fields across multiple records
  def test_context_shape_merges_fields_across_multiple_records
    skip("telemetry aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # example contexts deduplicates by key value
  def test_example_contexts_deduplicates_by_key_value
    skip("telemetry aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # telemetry disabled emits nothing
  def test_telemetry_disabled_emits_nothing
    skip("telemetry aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # shapes only mode reports shapes but not examples
  def test_shapes_only_mode_reports_shapes_but_not_examples
    skip("telemetry aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # log level evaluations are excluded from telemetry
  def test_log_level_evaluations_are_excluded_from_telemetry
    skip("telemetry aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # empty context produces no context telemetry
  def test_empty_context_produces_no_context_telemetry
    skip("telemetry aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end
end
