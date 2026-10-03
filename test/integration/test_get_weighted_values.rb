# frozen_string_literal: true

# AUTO-GENERATED from integration-test-data/tests/eval/get_weighted_values.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestGetWeightedValues < Minitest::Test
  # weighted value is consistent 1
  def test_weighted_value_is_consistent_1
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('feature-flag.weighted', context: { 'user' => { 'tracking_id' => 'a72c15f5' } })
    assert_equal 1, actual, 'client.get_int(feature-flag.weighted, context: { user => { tracking_id => a72c15f5 } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # weighted value is consistent 2
  def test_weighted_value_is_consistent_2
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('feature-flag.weighted', context: { 'user' => { 'tracking_id' => '92a202f2' } })
    assert_equal 2, actual, 'client.get_int(feature-flag.weighted, context: { user => { tracking_id => 92a202f2 } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # weighted value is consistent 3
  def test_weighted_value_is_consistent_3
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('feature-flag.weighted', context: { 'user' => { 'tracking_id' => '8f414100' } })
    assert_equal 3, actual, 'client.get_int(feature-flag.weighted, context: { user => { tracking_id => 8f414100 } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # even split ones serves first variant at low hash fraction
  def test_even_split_ones_serves_first_variant_at_low_hash_fraction
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('feature-flag.weighted.even-split-ones', context: { 'user' => { 'tracking_id' => 'b7ff78c8' } })
    assert_equal 'a', actual, 'client.get_string(feature-flag.weighted.even-split-ones, context: { user => { tracking_id => b7ff78c8 } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # even split ones serves first variant at low hash fraction 2
  def test_even_split_ones_serves_first_variant_at_low_hash_fraction_2
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('feature-flag.weighted.even-split-ones', context: { 'user' => { 'tracking_id' => '289f4748' } })
    assert_equal 'a', actual, 'client.get_string(feature-flag.weighted.even-split-ones, context: { user => { tracking_id => 289f4748 } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # even split ones serves second variant at high hash fraction
  def test_even_split_ones_serves_second_variant_at_high_hash_fraction
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('feature-flag.weighted.even-split-ones', context: { 'user' => { 'tracking_id' => 'd60b2cb6' } })
    assert_equal 'b', actual, 'client.get_string(feature-flag.weighted.even-split-ones, context: { user => { tracking_id => d60b2cb6 } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # even split ones serves second variant at high hash fraction 2
  def test_even_split_ones_serves_second_variant_at_high_hash_fraction_2
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('feature-flag.weighted.even-split-ones', context: { 'user' => { 'tracking_id' => '21bcfd13' } })
    assert_equal 'b', actual, 'client.get_string(feature-flag.weighted.even-split-ones, context: { user => { tracking_id => 21bcfd13 } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # non-ascii tracking_id emoji hashes utf-8 bytes
  def test_non_ascii_tracking_id_emoji_hashes_utf_8_bytes
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('feature-flag.weighted.even-split-ones', context: { 'user' => { 'tracking_id' => '🚀-rocket' } })
    assert_equal 'a', actual, 'client.get_string(feature-flag.weighted.even-split-ones, context: { user => { tracking_id => 🚀-rocket } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # non-ascii tracking_id latin hashes utf-8 bytes
  def test_non_ascii_tracking_id_latin_hashes_utf_8_bytes
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('feature-flag.weighted.even-split-ones', context: { 'user' => { 'tracking_id' => 'münchen-7' } })
    assert_equal 'a', actual, 'client.get_string(feature-flag.weighted.even-split-ones, context: { user => { tracking_id => münchen-7 } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # non-ascii tracking_id cjk hashes utf-8 bytes
  def test_non_ascii_tracking_id_cjk_hashes_utf_8_bytes
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('feature-flag.weighted.even-split-ones', context: { 'user' => { 'tracking_id' => 'ユーザー1' } })
    assert_equal 'b', actual, 'client.get_string(feature-flag.weighted.even-split-ones, context: { user => { tracking_id => ユーザー1 } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # non-standard sum still serves normalized true bucket
  def test_non_standard_sum_still_serves_normalized_true_bucket
    client = IntegrationTestHelpers.build_client
    actual = client.get_bool('feature-flag.weighted.non-standard', context: { 'user' => { 'tracking_id' => 'ff8adf17' } })
    assert_equal true, actual, 'client.get_bool(feature-flag.weighted.non-standard, context: { user => { tracking_id => ff8adf17 } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # non-standard sum still serves normalized true bucket 2
  def test_non_standard_sum_still_serves_normalized_true_bucket_2
    client = IntegrationTestHelpers.build_client
    actual = client.get_bool('feature-flag.weighted.non-standard', context: { 'user' => { 'tracking_id' => '36ef1a7a' } })
    assert_equal true, actual, 'client.get_bool(feature-flag.weighted.non-standard, context: { user => { tracking_id => 36ef1a7a } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # non-standard sum still serves normalized false bucket
  def test_non_standard_sum_still_serves_normalized_false_bucket
    client = IntegrationTestHelpers.build_client
    actual = client.get_bool('feature-flag.weighted.non-standard', context: { 'user' => { 'tracking_id' => 'f667c76a' } })
    assert_equal false, actual, 'client.get_bool(feature-flag.weighted.non-standard, context: { user => { tracking_id => f667c76a } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # non-standard sum still serves normalized false bucket 2
  def test_non_standard_sum_still_serves_normalized_false_bucket_2
    client = IntegrationTestHelpers.build_client
    actual = client.get_bool('feature-flag.weighted.non-standard', context: { 'user' => { 'tracking_id' => '7467ca21' } })
    assert_equal false, actual, 'client.get_bool(feature-flag.weighted.non-standard, context: { user => { tracking_id => 7467ca21 } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # weighted value with hash property missing from context hashes empty string
  def test_weighted_value_with_hash_property_missing_from_context_hashes_empty_string
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('feature-flag.weighted.missing-hash', context: { 'user' => { 'key' => 'no-tracking-id-user' } })
    assert_equal 2, actual, 'client.get_int(feature-flag.weighted.missing-hash, context: { user => { key => no-tracking-id-user } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # weighted value with no context hashes empty string
  def test_weighted_value_with_no_context_hashes_empty_string
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('feature-flag.weighted.missing-hash')
    assert_equal 2, actual, 'client.get_int(feature-flag.weighted.missing-hash)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # weighted value with hash property empty string hashes empty string
  def test_weighted_value_with_hash_property_empty_string_hashes_empty_string
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('feature-flag.weighted.missing-hash', context: { 'user' => { 'key' => 'empty-tracking-id-user', 'tracking_id' => '' } })
    assert_equal 2, actual, 'client.get_int(feature-flag.weighted.missing-hash, context: { user => { key => empty-tracking-id-user, tracking_id =>  } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # weighted value with zero-weight first variant and hash property missing never serves zero-weight variant
  def test_weighted_value_with_zero_weight_first_variant_and_hash_property_missing_never_serves_zero_weight_variant
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('feature-flag.weighted.zero-first', context: { 'user' => { 'key' => 'no-tracking-id-user' } })
    assert_equal 2, actual, 'client.get_int(feature-flag.weighted.zero-first, context: { user => { key => no-tracking-id-user } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # weighted value with no hash property is random on every evaluation
  def test_weighted_value_with_no_hash_property_is_random_on_every_evaluation
    client = IntegrationTestHelpers.build_client
    seen = Array.new(200) { client.get_int('feature-flag.weighted.no-hash') }.uniq
    assert_equal [1, 2].sort_by(&:inspect), seen.sort_by(&:inspect),
                 'expected values seen over 200 evaluations'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # weighted value with no hash property is random on every evaluation with context
  def test_weighted_value_with_no_hash_property_is_random_on_every_evaluation_with_context
    client = IntegrationTestHelpers.build_client
    seen = Array.new(200) { client.get_int('feature-flag.weighted.no-hash', context: { 'user' => { 'key' => 'same-user-every-time', 'tracking_id' => 'same-tracking-id' } }) }.uniq
    assert_equal [1, 2].sort_by(&:inspect), seen.sort_by(&:inspect),
                 'expected values seen over 200 evaluations'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end
end
