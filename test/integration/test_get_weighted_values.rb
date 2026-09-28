# frozen_string_literal: true

# AUTO-GENERATED from integration-test-data/tests/eval/get_weighted_values.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestGetWeightedValues < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store('get_weighted_values')
  end

  # weighted value is consistent 1
  def test_weighted_value_is_consistent_1
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(self, resolver, 'feature-flag.weighted', { 'user' => { 'tracking_id' => 'a72c15f5' } }, 1)
  end

  # weighted value is consistent 2
  def test_weighted_value_is_consistent_2
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(self, resolver, 'feature-flag.weighted', { 'user' => { 'tracking_id' => '92a202f2' } }, 2)
  end

  # weighted value is consistent 3
  def test_weighted_value_is_consistent_3
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(self, resolver, 'feature-flag.weighted', { 'user' => { 'tracking_id' => '8f414100' } }, 3)
  end

  # even split ones serves first variant at low hash fraction
  def test_even_split_ones_serves_first_variant_at_low_hash_fraction
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(self, resolver, 'feature-flag.weighted.even-split-ones', { 'user' => { 'tracking_id' => 'b7ff78c8' } }, 'a')
  end

  # even split ones serves first variant at low hash fraction 2
  def test_even_split_ones_serves_first_variant_at_low_hash_fraction_2
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(self, resolver, 'feature-flag.weighted.even-split-ones', { 'user' => { 'tracking_id' => '289f4748' } }, 'a')
  end

  # even split ones serves second variant at high hash fraction
  def test_even_split_ones_serves_second_variant_at_high_hash_fraction
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(self, resolver, 'feature-flag.weighted.even-split-ones', { 'user' => { 'tracking_id' => 'd60b2cb6' } }, 'b')
  end

  # even split ones serves second variant at high hash fraction 2
  def test_even_split_ones_serves_second_variant_at_high_hash_fraction_2
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(self, resolver, 'feature-flag.weighted.even-split-ones', { 'user' => { 'tracking_id' => '21bcfd13' } }, 'b')
  end

  # non-standard sum still serves normalized true bucket
  def test_non_standard_sum_still_serves_normalized_true_bucket
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(self, resolver, 'feature-flag.weighted.non-standard', { 'user' => { 'tracking_id' => 'ff8adf17' } }, true)
  end

  # non-standard sum still serves normalized true bucket 2
  def test_non_standard_sum_still_serves_normalized_true_bucket_2
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(self, resolver, 'feature-flag.weighted.non-standard', { 'user' => { 'tracking_id' => '36ef1a7a' } }, true)
  end

  # non-standard sum still serves normalized false bucket
  def test_non_standard_sum_still_serves_normalized_false_bucket
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(self, resolver, 'feature-flag.weighted.non-standard', { 'user' => { 'tracking_id' => 'f667c76a' } }, false)
  end

  # non-standard sum still serves normalized false bucket 2
  def test_non_standard_sum_still_serves_normalized_false_bucket_2
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(self, resolver, 'feature-flag.weighted.non-standard', { 'user' => { 'tracking_id' => '7467ca21' } }, false)
  end

  # weighted value with hash property missing from context hashes empty string
  def test_weighted_value_with_hash_property_missing_from_context_hashes_empty_string
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(self, resolver, 'feature-flag.weighted.missing-hash', { 'user' => { 'key' => 'no-tracking-id-user' } }, 2)
  end

  # weighted value with no context hashes empty string
  def test_weighted_value_with_no_context_hashes_empty_string
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(self, resolver, 'feature-flag.weighted.missing-hash', {}, 2)
  end

  # weighted value with hash property empty string hashes empty string
  def test_weighted_value_with_hash_property_empty_string_hashes_empty_string
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(self, resolver, 'feature-flag.weighted.missing-hash', { 'user' => { 'key' => 'empty-tracking-id-user', 'tracking_id' => '' } }, 2)
  end

  # weighted value with zero-weight first variant and hash property missing never serves zero-weight variant
  def test_weighted_value_with_zero_weight_first_variant_and_hash_property_missing_never_serves_zero_weight_variant
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(self, resolver, 'feature-flag.weighted.zero-first', { 'user' => { 'key' => 'no-tracking-id-user' } }, 2)
  end

  # weighted value with no hash property is random on every evaluation
  def test_weighted_value_with_no_hash_property_is_random_on_every_evaluation
    resolver = IntegrationTestHelpers.build_resolver(@store)
    ctx = Quonfig::Context.new({})
    seen = Array.new(200) { resolver.get('feature-flag.weighted.no-hash', ctx)&.unwrapped_value }.uniq
    assert_equal [1, 2].sort_by(&:inspect), seen.sort_by(&:inspect),
                 'expected values seen over 200 evaluations'
  end

  # weighted value with no hash property is random on every evaluation with context
  def test_weighted_value_with_no_hash_property_is_random_on_every_evaluation_with_context
    resolver = IntegrationTestHelpers.build_resolver(@store)
    ctx = Quonfig::Context.new({ 'user' => { 'key' => 'same-user-every-time', 'tracking_id' => 'same-tracking-id' } })
    seen = Array.new(200) { resolver.get('feature-flag.weighted.no-hash', ctx)&.unwrapped_value }.uniq
    assert_equal [1, 2].sort_by(&:inspect), seen.sort_by(&:inspect),
                 'expected values seen over 200 evaluations'
  end
end
