# frozen_string_literal: true
#
# AUTO-GENERATED from integration-test-data/tests/eval/post.yaml.
# Regenerate with `bundle exec ruby scripts/generate_integration_tests.rb`.
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestPost < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store("post")
  end

  # reports context shape aggregation
  def test_reports_context_shape_aggregation
    skip("post/aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # reports evaluation summary
  def test_reports_evaluation_summary
    skip("post/aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # reports example contexts
  def test_reports_example_contexts
    skip("post/aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end

  # example contexts without key are not reported
  def test_example_contexts_without_key_are_not_reported
    skip("post/aggregator integration not yet wired in sdk-ruby (qfg-dk6.x)")
  end
end
