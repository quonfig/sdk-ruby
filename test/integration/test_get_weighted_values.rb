# frozen_string_literal: true
#
# AUTO-GENERATED from integration-test-data/tests/eval/get_weighted_values.yaml.
# Regenerate with `bundle exec ruby scripts/generate_integration_tests.rb`.
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestGetWeightedValues < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store("get_weighted_values")
  end

  # weighted value is consistent 1
  def test_weighted_value_is_consistent_1
    skip("weighted resolver not yet ported to JSON criteria (qfg-dk6.x)")
  end

  # weighted value is consistent 2
  def test_weighted_value_is_consistent_2
    skip("weighted resolver not yet ported to JSON criteria (qfg-dk6.x)")
  end

  # weighted value is consistent 3
  def test_weighted_value_is_consistent_3
    skip("weighted resolver not yet ported to JSON criteria (qfg-dk6.x)")
  end
end
