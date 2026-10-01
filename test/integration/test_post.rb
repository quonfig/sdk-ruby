# frozen_string_literal: true

# AUTO-GENERATED from integration-test-data/tests/eval/post.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestPost < Minitest::Test
  # reports context shape aggregation
  def test_reports_context_shape_aggregation
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink, context_upload_mode: :shapes_only)
    client.with_context({ 'user' => { 'name' => 'Michael', 'age' => 38, 'human' => true }, 'role' => { 'name' => 'developer', 'admin' => false, 'salary' => 15.75, 'permissions' => %w[read write] } }).get_or_raise('brand.new.string')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :context_shape, [{ 'name' => 'user', 'field_types' => { 'name' => 2, 'age' => 1, 'human' => 5 } }, { 'name' => 'role', 'field_types' => { 'name' => 2, 'admin' => 5, 'salary' => 4, 'permissions' => 10 } }],
                                                 endpoint: '/api/v1/context-shapes')
  ensure
    client&.stop
    sink&.stop
  end

  # reports evaluation summary
  def test_reports_evaluation_summary
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    returned = Hash.new { |h, k| h[k] = [] }
    scope = client.with_context({ 'user' => { 'tracking_id' => '92a202f2' } })
    returned['my-test-key'] << scope.get_or_raise('my-test-key')
    returned['feature-flag.integer'] << scope.get_or_raise('feature-flag.integer')
    returned['my-string-list-key'] << scope.get_or_raise('my-string-list-key')
    returned['feature-flag.integer'] << scope.get_or_raise('feature-flag.integer')
    returned['feature-flag.weighted'] << scope.get_or_raise('feature-flag.weighted')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :evaluation_summary, [{ 'key' => 'my-test-key', 'type' => 'CONFIG', 'value' => 'my-test-value', 'value_type' => 'string', 'count' => 1, 'reason' => 2, 'selected_value' => { 'string' => 'my-test-value' }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 1 } }, { 'key' => 'my-string-list-key', 'type' => 'CONFIG', 'value' => %w[a b c], 'value_type' => 'string_list', 'count' => 1, 'reason' => 1, 'selected_value' => { 'stringList' => %w[a b c] }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 0 } }, { 'key' => 'feature-flag.integer', 'type' => 'FEATURE_FLAG', 'value' => 3, 'value_type' => 'int', 'count' => 2, 'reason' => 2, 'selected_value' => { 'int' => 3 }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 1 } }, { 'key' => 'feature-flag.weighted', 'type' => 'FEATURE_FLAG', 'value' => 2, 'value_type' => 'int', 'count' => 1, 'reason' => 3, 'selected_value' => { 'int' => 2 }, 'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 0, 'weighted_value_index' => 2 } }],
                                                 endpoint: '/api/v1/telemetry', returned: returned)
  ensure
    client&.stop
    sink&.stop
  end

  # reports example contexts
  def test_reports_example_contexts
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    client.with_context({ 'user' => { 'name' => 'michael', 'age' => 38, 'key' => 'michael:1234' }, 'device' => { 'mobile' => false }, 'team' => { 'id' => 3.5 } }).get_or_raise('brand.new.string')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :example_contexts, { 'user' => { 'name' => 'michael', 'age' => 38, 'key' => 'michael:1234' }, 'device' => { 'mobile' => false }, 'team' => { 'id' => 3.5 } },
                                                 endpoint: '/api/v1/telemetry')
  ensure
    client&.stop
    sink&.stop
  end

  # example contexts without key are not reported
  def test_example_contexts_without_key_are_not_reported
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    client.with_context({ 'user' => { 'name' => 'michael', 'age' => 38 }, 'device' => { 'mobile' => false }, 'team' => { 'id' => 3.5 } }).get_or_raise('brand.new.string')
    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :example_contexts, nil,
                                                 endpoint: '/api/v1/telemetry')
  ensure
    client&.stop
    sink&.stop
  end
end
