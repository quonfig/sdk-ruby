# frozen_string_literal: true

# AUTO-GENERATED from integration-test-data/tests/eval/telemetry.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestTelemetry < Minitest::Test
  # reason is STATIC for config with no targeting rules
  def test_reason_is_static_for_config_with_no_targeting_rules
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    returned = Hash.new { |h, k| h[k] = [] }
    returned['brand.new.string'] << client.get_or_raise('brand.new.string')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :evaluation_summary, [{ 'key' => 'brand.new.string', 'type' => 'CONFIG', 'value' => 'hello.world', 'value_type' => 'string', 'count' => 1, 'reason' => 1, 'selected_value' => { 'string' => 'hello.world' }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 0 } }],
                                                 endpoint: '/api/v1/telemetry', returned: returned)
  ensure
    client&.stop
    sink&.stop
  end

  # reason is STATIC for feature flag with only ALWAYS_TRUE rules
  def test_reason_is_static_for_feature_flag_with_only_always_true_rules
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    returned = Hash.new { |h, k| h[k] = [] }
    returned['always.true'] << client.get_or_raise('always.true')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :evaluation_summary, [{ 'key' => 'always.true', 'type' => 'FEATURE_FLAG', 'value' => true, 'value_type' => 'bool', 'count' => 1, 'reason' => 1, 'selected_value' => { 'bool' => true }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 0 } }],
                                                 endpoint: '/api/v1/telemetry', returned: returned)
  ensure
    client&.stop
    sink&.stop
  end

  # reason is TARGETING_MATCH when config has targeting rules but evaluation falls through
  def test_reason_is_targeting_match_when_config_has_targeting_rules_but_evaluation_falls_through
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    returned = Hash.new { |h, k| h[k] = [] }
    returned['my-test-key'] << client.get_or_raise('my-test-key')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :evaluation_summary, [{ 'key' => 'my-test-key', 'type' => 'CONFIG', 'value' => 'my-test-value', 'value_type' => 'string', 'count' => 1, 'reason' => 2, 'selected_value' => { 'string' => 'my-test-value' }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 1 } }],
                                                 endpoint: '/api/v1/telemetry', returned: returned)
  ensure
    client&.stop
    sink&.stop
  end

  # reason is TARGETING_MATCH when a targeting rule matches
  def test_reason_is_targeting_match_when_a_targeting_rule_matches
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    returned = Hash.new { |h, k| h[k] = [] }
    scope = client.with_context({ 'user' => { 'key' => 'michael' } })
    returned['feature-flag.integer'] << scope.get_or_raise('feature-flag.integer')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :evaluation_summary, [{ 'key' => 'feature-flag.integer', 'type' => 'FEATURE_FLAG', 'value' => 5, 'value_type' => 'int', 'count' => 1, 'reason' => 2, 'selected_value' => { 'int' => 5 }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 0 } }],
                                                 endpoint: '/api/v1/telemetry', returned: returned)
  ensure
    client&.stop
    sink&.stop
  end

  # reason is SPLIT for weighted value evaluation
  def test_reason_is_split_for_weighted_value_evaluation
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    returned = Hash.new { |h, k| h[k] = [] }
    scope = client.with_context({ 'user' => { 'tracking_id' => '92a202f2' } })
    returned['feature-flag.weighted'] << scope.get_or_raise('feature-flag.weighted')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :evaluation_summary, [{ 'key' => 'feature-flag.weighted', 'type' => 'FEATURE_FLAG', 'value' => 2, 'value_type' => 'int', 'count' => 1, 'reason' => 3, 'selected_value' => { 'int' => 2 }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 0, 'weighted_value_index' => 2 } }],
                                                 endpoint: '/api/v1/telemetry', returned: returned)
  ensure
    client&.stop
    sink&.stop
  end

  # reason is SPLIT for weighted value landing in bucket 0
  def test_reason_is_split_for_weighted_value_landing_in_bucket_0
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    returned = Hash.new { |h, k| h[k] = [] }
    scope = client.with_context({ 'user' => { 'tracking_id' => '3e9459d6' } })
    returned['feature-flag.weighted'] << scope.get_or_raise('feature-flag.weighted')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :evaluation_summary, [{ 'key' => 'feature-flag.weighted', 'type' => 'FEATURE_FLAG', 'value' => 1, 'value_type' => 'int', 'count' => 1, 'reason' => 3, 'selected_value' => { 'int' => 1 }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 0, 'weighted_value_index' => 0 } }],
                                                 endpoint: '/api/v1/telemetry', returned: returned)
  ensure
    client&.stop
    sink&.stop
  end

  # reason is TARGETING_MATCH for feature flag fallthrough with targeting rules
  def test_reason_is_targeting_match_for_feature_flag_fallthrough_with_targeting_rules
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    returned = Hash.new { |h, k| h[k] = [] }
    returned['feature-flag.integer'] << client.get_or_raise('feature-flag.integer')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :evaluation_summary, [{ 'key' => 'feature-flag.integer', 'type' => 'FEATURE_FLAG', 'value' => 3, 'value_type' => 'int', 'count' => 1, 'reason' => 2, 'selected_value' => { 'int' => 3 }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 1 } }],
                                                 endpoint: '/api/v1/telemetry', returned: returned)
  ensure
    client&.stop
    sink&.stop
  end

  # evaluation summary deduplicates identical evaluations
  def test_evaluation_summary_deduplicates_identical_evaluations
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    returned = Hash.new { |h, k| h[k] = [] }
    returned['brand.new.string'] << client.get_or_raise('brand.new.string')
    returned['brand.new.string'] << client.get_or_raise('brand.new.string')
    returned['brand.new.string'] << client.get_or_raise('brand.new.string')
    returned['brand.new.string'] << client.get_or_raise('brand.new.string')
    returned['brand.new.string'] << client.get_or_raise('brand.new.string')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :evaluation_summary, [{ 'key' => 'brand.new.string', 'type' => 'CONFIG', 'value' => 'hello.world', 'value_type' => 'string', 'count' => 5, 'reason' => 1, 'selected_value' => { 'string' => 'hello.world' }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 0 } }],
                                                 endpoint: '/api/v1/telemetry', returned: returned)
  ensure
    client&.stop
    sink&.stop
  end

  # evaluation summary creates separate counters for different rules of same config
  def test_evaluation_summary_creates_separate_counters_for_different_rules_of_same_config
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    returned = Hash.new { |h, k| h[k] = [] }
    scope = client.with_context({ 'user' => { 'key' => 'michael' } })
    returned['feature-flag.integer'] << scope.get_or_raise('feature-flag.integer')
    returned['feature-flag.integer'] << client.get_or_raise('feature-flag.integer')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :evaluation_summary, [{ 'key' => 'feature-flag.integer', 'type' => 'FEATURE_FLAG', 'value' => 5, 'value_type' => 'int', 'count' => 1, 'reason' => 2, 'selected_value' => { 'int' => 5 }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 0 } }, { 'key' => 'feature-flag.integer', 'type' => 'FEATURE_FLAG', 'value' => 3, 'value_type' => 'int', 'count' => 1, 'reason' => 2, 'selected_value' => { 'int' => 3 }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 1 } }],
                                                 endpoint: '/api/v1/telemetry', returned: returned)
  ensure
    client&.stop
    sink&.stop
  end

  # evaluation summary groups by config key
  def test_evaluation_summary_groups_by_config_key
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    returned = Hash.new { |h, k| h[k] = [] }
    returned['brand.new.string'] << client.get_or_raise('brand.new.string')
    returned['always.true'] << client.get_or_raise('always.true')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :evaluation_summary, [{ 'key' => 'brand.new.string', 'type' => 'CONFIG', 'value' => 'hello.world', 'value_type' => 'string', 'count' => 1, 'reason' => 1, 'selected_value' => { 'string' => 'hello.world' }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 0 } }, { 'key' => 'always.true', 'type' => 'FEATURE_FLAG', 'value' => true, 'value_type' => 'bool', 'count' => 1, 'reason' => 1, 'selected_value' => { 'bool' => true }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 0 } }],
                                                 endpoint: '/api/v1/telemetry', returned: returned)
  ensure
    client&.stop
    sink&.stop
  end

  # selectedValue wraps string correctly
  def test_selectedvalue_wraps_string_correctly
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    returned = Hash.new { |h, k| h[k] = [] }
    returned['brand.new.string'] << client.get_or_raise('brand.new.string')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :evaluation_summary, [{ 'key' => 'brand.new.string', 'type' => 'CONFIG', 'value' => 'hello.world', 'value_type' => 'string', 'count' => 1, 'reason' => 1, 'selected_value' => { 'string' => 'hello.world' }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 0 } }],
                                                 endpoint: '/api/v1/telemetry', returned: returned)
  ensure
    client&.stop
    sink&.stop
  end

  # selectedValue wraps boolean correctly
  def test_selectedvalue_wraps_boolean_correctly
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    returned = Hash.new { |h, k| h[k] = [] }
    returned['brand.new.boolean'] << client.get_or_raise('brand.new.boolean')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :evaluation_summary, [{ 'key' => 'brand.new.boolean', 'type' => 'CONFIG', 'value' => false, 'value_type' => 'bool', 'count' => 1, 'reason' => 1, 'selected_value' => { 'bool' => false }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 0 } }],
                                                 endpoint: '/api/v1/telemetry', returned: returned)
  ensure
    client&.stop
    sink&.stop
  end

  # selectedValue wraps int correctly
  def test_selectedvalue_wraps_int_correctly
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    returned = Hash.new { |h, k| h[k] = [] }
    returned['brand.new.int'] << client.get_or_raise('brand.new.int')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :evaluation_summary, [{ 'key' => 'brand.new.int', 'type' => 'CONFIG', 'value' => 123, 'value_type' => 'int', 'count' => 1, 'reason' => 1, 'selected_value' => { 'int' => 123 }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 0 } }],
                                                 endpoint: '/api/v1/telemetry', returned: returned)
  ensure
    client&.stop
    sink&.stop
  end

  # selectedValue wraps double correctly
  def test_selectedvalue_wraps_double_correctly
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    returned = Hash.new { |h, k| h[k] = [] }
    returned['brand.new.double'] << client.get_or_raise('brand.new.double')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :evaluation_summary, [{ 'key' => 'brand.new.double', 'type' => 'CONFIG', 'value' => 123.99, 'value_type' => 'double', 'count' => 1, 'reason' => 1, 'selected_value' => { 'double' => 123.99 }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 0 } }],
                                                 endpoint: '/api/v1/telemetry', returned: returned)
  ensure
    client&.stop
    sink&.stop
  end

  # selectedValue wraps string list correctly
  def test_selectedvalue_wraps_string_list_correctly
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    returned = Hash.new { |h, k| h[k] = [] }
    returned['my-string-list-key'] << client.get_or_raise('my-string-list-key')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :evaluation_summary, [{ 'key' => 'my-string-list-key', 'type' => 'CONFIG', 'value' => %w[a b c], 'value_type' => 'string_list', 'count' => 1, 'reason' => 1, 'selected_value' => { 'stringList' => %w[a b c] }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 0 } }],
                                                 endpoint: '/api/v1/telemetry', returned: returned)
  ensure
    client&.stop
    sink&.stop
  end

  # context shape merges fields across multiple records
  def test_context_shape_merges_fields_across_multiple_records
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    client.with_context({ 'user' => { 'name' => 'alice', 'age' => 30 } }).get_or_raise('brand.new.string')
    client.with_context({ 'user' => { 'name' => 'bob', 'score' => 9.5 }, 'team' => { 'name' => 'engineering' } }).get_or_raise('brand.new.string')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :context_shape, [{ 'name' => 'user', 'field_types' => { 'name' => 2, 'age' => 1, 'score' => 4 } }, { 'name' => 'team', 'field_types' => { 'name' => 2 } }],
                                                 endpoint: '/api/v1/context-shapes')
  ensure
    client&.stop
    sink&.stop
  end

  # example contexts deduplicates by key value
  def test_example_contexts_deduplicates_by_key_value
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    client.with_context({ 'user' => { 'key' => 'user-123', 'name' => 'alice' } }).get_or_raise('brand.new.string')
    client.with_context({ 'user' => { 'key' => 'user-123', 'name' => 'bob' } }).get_or_raise('brand.new.string')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :example_contexts, { 'user' => { 'key' => 'user-123', 'name' => 'alice' } },
                                                 endpoint: '/api/v1/telemetry')
  ensure
    client&.stop
    sink&.stop
  end

  # telemetry disabled emits nothing
  def test_telemetry_disabled_emits_nothing
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink, collect_evaluation_summaries: false, context_upload_mode: :none)
    returned = Hash.new { |h, k| h[k] = [] }
    returned['brand.new.string'] << client.get_or_raise('brand.new.string')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :evaluation_summary, nil,
                                                 endpoint: '/api/v1/telemetry', returned: returned)
  ensure
    client&.stop
    sink&.stop
  end

  # shapes only mode reports shapes but not examples
  def test_shapes_only_mode_reports_shapes_but_not_examples
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink, context_upload_mode: :shapes_only)
    client.with_context({ 'user' => { 'name' => 'alice', 'key' => 'alice-123' } }).get_or_raise('brand.new.string')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :context_shape, [{ 'name' => 'user', 'field_types' => { 'name' => 2, 'key' => 2 } }],
                                                 endpoint: '/api/v1/context-shapes')
  ensure
    client&.stop
    sink&.stop
  end

  # log level evaluations are excluded from telemetry
  def test_log_level_evaluations_are_excluded_from_telemetry
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    returned = Hash.new { |h, k| h[k] = [] }
    returned['log-level.prefab.criteria_evaluator'] << client.get_or_raise('log-level.prefab.criteria_evaluator')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :evaluation_summary, nil,
                                                 endpoint: '/api/v1/telemetry', returned: returned)
  ensure
    client&.stop
    sink&.stop
  end

  # empty context produces no context telemetry
  def test_empty_context_produces_no_context_telemetry
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    client.with_context({}).get_or_raise('brand.new.string')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :context_shape, nil,
                                                 endpoint: '/api/v1/context-shapes')
  ensure
    client&.stop
    sink&.stop
  end

  # confidential plain string is redacted in selectedValue
  def test_confidential_plain_string_is_redacted_in_selectedvalue
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    returned = Hash.new { |h, k| h[k] = [] }
    returned['confidential.new.string'] << client.get_or_raise('confidential.new.string')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :evaluation_summary, [{ 'key' => 'confidential.new.string', 'type' => 'CONFIG', 'value' => 'hello.world', 'value_type' => 'string', 'count' => 1, 'reason' => 1, 'selected_value' => { 'string' => '*****18aa7' }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 0 } }],
                                                 endpoint: '/api/v1/telemetry', returned: returned)
  ensure
    client&.stop
    sink&.stop
  end

  # confidential encrypted string is redacted using ciphertext hash
  def test_confidential_encrypted_string_is_redacted_using_ciphertext_hash
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    returned = Hash.new { |h, k| h[k] = [] }
    returned['a.secret.config'] << client.get_or_raise('a.secret.config')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :evaluation_summary, [{ 'key' => 'a.secret.config', 'type' => 'CONFIG', 'value' => 'hello.world', 'value_type' => 'string', 'count' => 1, 'reason' => 1, 'selected_value' => { 'string' => '*****936c9' }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 0 } }],
                                                 endpoint: '/api/v1/telemetry', returned: returned)
  ensure
    client&.stop
    sink&.stop
  end
end
