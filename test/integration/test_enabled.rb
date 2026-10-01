# frozen_string_literal: true

# AUTO-GENERATED from integration-test-data/tests/eval/enabled.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestEnabled < Minitest::Test
  # returns the correct value for a simple flag
  def test_returns_the_correct_value_for_a_simple_flag
    client = IntegrationTestHelpers.build_client
    actual = client.enabled?('feature-flag.simple')
    assert_equal true, actual, 'client.enabled?(feature-flag.simple)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # always returns false for a non-boolean flag
  def test_always_returns_false_for_a_non_boolean_flag
    client = IntegrationTestHelpers.build_client
    actual = client.enabled?('feature-flag.integer')
    assert_equal false, actual, 'client.enabled?(feature-flag.integer)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for a PROP_IS_ONE_OF rule when any prop matches
  def test_returns_true_for_a_prop_is_one_of_rule_when_any_prop_matches
    client = IntegrationTestHelpers.build_client
    actual = client.enabled?('feature-flag.properties.positive', { '' => { 'name' => 'michael', 'domain' => 'something.com' } })
    assert_equal true, actual, 'client.enabled?(feature-flag.properties.positive, {  => { name => michael, domain => something.com } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for a PROP_IS_ONE_OF rule when no prop matches
  def test_returns_false_for_a_prop_is_one_of_rule_when_no_prop_matches
    client = IntegrationTestHelpers.build_client
    actual = client.enabled?('feature-flag.properties.positive', { '' => { 'name' => 'lauren', 'domain' => 'something.com' } })
    assert_equal false, actual, 'client.enabled?(feature-flag.properties.positive, {  => { name => lauren, domain => something.com } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for a PROP_IS_NOT_ONE_OF rule when any prop doesn't match
  def test_returns_true_for_a_prop_is_not_one_of_rule_when_any_prop_doesn_t_match
    client = IntegrationTestHelpers.build_client
    actual = client.enabled?('feature-flag.properties.negative', { '' => { 'name' => 'lauren', 'domain' => 'prefab.cloud' } })
    assert_equal true, actual, 'client.enabled?(feature-flag.properties.negative, {  => { name => lauren, domain => prefab.cloud } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for a PROP_IS_NOT_ONE_OF rule when all props match
  def test_returns_false_for_a_prop_is_not_one_of_rule_when_all_props_match
    client = IntegrationTestHelpers.build_client
    actual = client.enabled?('feature-flag.properties.negative', { '' => { 'name' => 'michael', 'domain' => 'prefab.cloud' } })
    assert_equal false, actual, 'client.enabled?(feature-flag.properties.negative, {  => { name => michael, domain => prefab.cloud } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_ENDS_WITH_ONE_OF rule when the given prop has a matching suffix
  def test_returns_true_for_prop_ends_with_one_of_rule_when_the_given_prop_has_a_matching_suffix
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ '' => { 'email' => 'jeff@prefab.cloud' } })
    actual = scope.enabled?('feature-flag.ends-with-one-of.positive')
    assert_equal true, actual, 'scope.enabled?(feature-flag.ends-with-one-of.positive)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_ENDS_WITH_ONE_OF rule when the given prop doesn't have a matching suffix
  def test_returns_false_for_prop_ends_with_one_of_rule_when_the_given_prop_doesn_t_have_a_matching_suffix
    client = IntegrationTestHelpers.build_client
    actual = client.enabled?('feature-flag.ends-with-one-of.positive', { '' => { 'email' => 'jeff@test.com' } })
    assert_equal false, actual, 'client.enabled?(feature-flag.ends-with-one-of.positive, {  => { email => jeff@test.com } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_DOES_NOT_END_WITH_ONE_OF rule when the given prop doesn't have a matching suffix
  def test_returns_true_for_prop_does_not_end_with_one_of_rule_when_the_given_prop_doesn_t_have_a_matching_suffix
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ '' => { 'email' => 'michael@test.com' } })
    actual = scope.enabled?('feature-flag.ends-with-one-of.negative')
    assert_equal true, actual, 'scope.enabled?(feature-flag.ends-with-one-of.negative)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_DOES_NOT_END_WITH_ONE_OF rule when the given prop has a matching suffix
  def test_returns_false_for_prop_does_not_end_with_one_of_rule_when_the_given_prop_has_a_matching_suffix
    client = IntegrationTestHelpers.build_client
    actual = client.enabled?('feature-flag.ends-with-one-of.negative', { '' => { 'email' => 'michael@prefab.cloud' } })
    assert_equal false, actual, 'client.enabled?(feature-flag.ends-with-one-of.negative, {  => { email => michael@prefab.cloud } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_STARTS_WITH_ONE_OF rule when the given prop has a matching prefix
  def test_returns_true_for_prop_starts_with_one_of_rule_when_the_given_prop_has_a_matching_prefix
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'email' => 'foo@prefab.cloud' } })
    actual = scope.enabled?('feature-flag.starts-with-one-of.positive')
    assert_equal true, actual, 'scope.enabled?(feature-flag.starts-with-one-of.positive)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_STARTS_WITH_ONE_OF rule when the given prop doesn't have a matching prefix
  def test_returns_false_for_prop_starts_with_one_of_rule_when_the_given_prop_doesn_t_have_a_matching_prefix
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'email' => 'notfoo@prefab.cloud' } })
    actual = scope.enabled?('feature-flag.starts-with-one-of.positive')
    assert_equal false, actual, 'scope.enabled?(feature-flag.starts-with-one-of.positive)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_DOES_NOT_START_WITH_ONE_OF rule when the given prop doesn't have a matching prefix
  def test_returns_true_for_prop_does_not_start_with_one_of_rule_when_the_given_prop_doesn_t_have_a_matching_prefix
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'email' => 'notfoo@prefab.cloud' } })
    actual = scope.enabled?('feature-flag.starts-with-one-of.negative')
    assert_equal true, actual, 'scope.enabled?(feature-flag.starts-with-one-of.negative)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_DOES_NOT_START_WITH_ONE_OF rule when the given prop has a matching prefix
  def test_returns_false_for_prop_does_not_start_with_one_of_rule_when_the_given_prop_has_a_matching_prefix
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'email' => 'foo@prefab.cloud' } })
    actual = scope.enabled?('feature-flag.starts-with-one-of.negative')
    assert_equal false, actual, 'scope.enabled?(feature-flag.starts-with-one-of.negative)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_CONTAINS_ONE_OF rule when the given prop has a matching substring
  def test_returns_true_for_prop_contains_one_of_rule_when_the_given_prop_has_a_matching_substring
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'email' => 'somefoo@prefab.cloud' } })
    actual = scope.enabled?('feature-flag.contains-one-of.positive')
    assert_equal true, actual, 'scope.enabled?(feature-flag.contains-one-of.positive)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_CONTAINS_ONE_OF rule when the given prop doesn't have a matching substring
  def test_returns_false_for_prop_contains_one_of_rule_when_the_given_prop_doesn_t_have_a_matching_substring
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'email' => 'info@prefab.cloud' } })
    actual = scope.enabled?('feature-flag.contains-one-of.positive')
    assert_equal false, actual, 'scope.enabled?(feature-flag.contains-one-of.positive)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_DOES_NOT_CONTAIN_ONE_OF rule when the given prop doesn't have a matching substring
  def test_returns_true_for_prop_does_not_contain_one_of_rule_when_the_given_prop_doesn_t_have_a_matching_substring
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'email' => 'info@prefab.cloud' } })
    actual = scope.enabled?('feature-flag.contains-one-of.negative')
    assert_equal true, actual, 'scope.enabled?(feature-flag.contains-one-of.negative)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_DOES_NOT_CONTAIN_ONE_OF rule when the given prop has a matching substring
  def test_returns_false_for_prop_does_not_contain_one_of_rule_when_the_given_prop_has_a_matching_substring
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'email' => 'notfoo@prefab.cloud' } })
    actual = scope.enabled?('feature-flag.contains-one-of.negative')
    assert_equal false, actual, 'scope.enabled?(feature-flag.contains-one-of.negative)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for IN_SEG when the segment rule matches
  def test_returns_true_for_in_seg_when_the_segment_rule_matches
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'key' => 'lauren' } })
    actual = scope.enabled?('feature-flag.in-segment.positive')
    assert_equal true, actual, 'scope.enabled?(feature-flag.in-segment.positive)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for IN_SEG when the segment rule doesn't match
  def test_returns_false_for_in_seg_when_the_segment_rule_doesn_t_match
    client = IntegrationTestHelpers.build_client
    actual = client.enabled?('feature-flag.in-segment.positive', { 'user' => { 'key' => 'josh' } })
    assert_equal false, actual, 'client.enabled?(feature-flag.in-segment.positive, { user => { key => josh } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for IN_SEG if any segment rule fails to match
  def test_returns_false_for_in_seg_if_any_segment_rule_fails_to_match
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'key' => 'josh' }, '' => { 'domain' => 'prefab.cloud' } })
    actual = scope.enabled?('feature-flag.in-seg.segment-and')
    assert_equal false, actual, 'scope.enabled?(feature-flag.in-seg.segment-and)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for IN_SEG (segment-and) if all rules matches
  def test_returns_true_for_in_seg_segment_and_if_all_rules_matches
    client = IntegrationTestHelpers.build_client
    actual = client.enabled?('feature-flag.in-seg.segment-and', { 'user' => { 'key' => 'michael' }, '' => { 'domain' => 'prefab.cloud' } })
    assert_equal true, actual, 'client.enabled?(feature-flag.in-seg.segment-and, { user => { key => michael },  => { domain => prefab.cloud } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for IN_SEG (segment-or) if any segment rule matches (lookup)
  def test_returns_true_for_in_seg_segment_or_if_any_segment_rule_matches_lookup
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'key' => 'michael' }, '' => { 'domain' => 'example.com' } })
    actual = scope.enabled?('feature-flag.in-seg.segment-or')
    assert_equal true, actual, 'scope.enabled?(feature-flag.in-seg.segment-or)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for IN_SEG (segment-or) if any segment rule matches (prop)
  def test_returns_true_for_in_seg_segment_or_if_any_segment_rule_matches_prop
    client = IntegrationTestHelpers.build_client
    actual = client.enabled?('feature-flag.in-seg.segment-or', { 'user' => { 'key' => 'nobody' }, '' => { 'domain' => 'gmail.com' } })
    assert_equal true, actual, 'client.enabled?(feature-flag.in-seg.segment-or, { user => { key => nobody },  => { domain => gmail.com } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for NOT_IN_SEG when the segment rule doesn't match
  def test_returns_true_for_not_in_seg_when_the_segment_rule_doesn_t_match
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'key' => 'josh' } })
    actual = scope.enabled?('feature-flag.in-segment.negative')
    assert_equal true, actual, 'scope.enabled?(feature-flag.in-segment.negative)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for NOT_IN_SEG when the segment rule matches
  def test_returns_false_for_not_in_seg_when_the_segment_rule_matches
    client = IntegrationTestHelpers.build_client
    actual = client.enabled?('feature-flag.in-segment.negative', { 'user' => { 'key' => 'michael' } })
    assert_equal false, actual, 'client.enabled?(feature-flag.in-segment.negative, { user => { key => michael } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for NOT_IN_SEG if any segment rule matches
  def test_returns_false_for_not_in_seg_if_any_segment_rule_matches
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'key' => 'josh' }, '' => { 'domain' => 'prefab.cloud' } })
    actual = scope.enabled?('feature-flag.in-segment.multiple-criteria.negative')
    assert_equal true, actual, 'scope.enabled?(feature-flag.in-segment.multiple-criteria.negative)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for NOT_IN_SEG if no segment rule matches
  def test_returns_true_for_not_in_seg_if_no_segment_rule_matches
    client = IntegrationTestHelpers.build_client
    actual = client.enabled?('feature-flag.in-segment.multiple-criteria.negative', { 'user' => { 'key' => 'josh' }, '' => { 'domain' => 'something.com' } })
    assert_equal true, actual, 'client.enabled?(feature-flag.in-segment.multiple-criteria.negative, { user => { key => josh },  => { domain => something.com } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for NOT_IN_SEG (segment-and) if not segment rule fails to match
  def test_returns_true_for_not_in_seg_segment_and_if_not_segment_rule_fails_to_match
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'key' => 'josh' }, '' => { 'domain' => 'prefab.cloud' } })
    actual = scope.enabled?('feature-flag.not-in-seg.segment-and')
    assert_equal true, actual, 'scope.enabled?(feature-flag.not-in-seg.segment-and)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for IN_SEG (segment-and) if not segment rule fails to match
  def test_returns_true_for_in_seg_segment_and_if_not_segment_rule_fails_to_match
    client = IntegrationTestHelpers.build_client
    actual = client.enabled?('feature-flag.in-seg.segment-and', { 'user' => { 'key' => 'josh' }, '' => { 'domain' => 'prefab.cloud' } })
    assert_equal false, actual, 'client.enabled?(feature-flag.in-seg.segment-and, { user => { key => josh },  => { domain => prefab.cloud } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for NOT_IN_SEG (segment-and) if segment rules matches
  def test_returns_false_for_not_in_seg_segment_and_if_segment_rules_matches
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'key' => 'michael' }, '' => { 'domain' => 'prefab.cloud' } })
    actual = scope.enabled?('feature-flag.not-in-seg.segment-and')
    assert_equal false, actual, 'scope.enabled?(feature-flag.not-in-seg.segment-and)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for NOT_IN_SEG (segment-or) if no segment rule matches
  def test_returns_true_for_not_in_seg_segment_or_if_no_segment_rule_matches
    client = IntegrationTestHelpers.build_client
    actual = client.enabled?('feature-flag.not-in-seg.segment-or', { 'user' => { 'key' => 'nobody' }, '' => { 'domain' => 'example.com' } })
    assert_equal true, actual, 'client.enabled?(feature-flag.not-in-seg.segment-or, { user => { key => nobody },  => { domain => example.com } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for NOT_IN_SEG (segment-or) if one segment rule matches (prop)
  def test_returns_false_for_not_in_seg_segment_or_if_one_segment_rule_matches_prop
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'key' => 'nobody' }, '' => { 'domain' => 'gmail.com' } })
    actual = scope.enabled?('feature-flag.not-in-seg.segment-or')
    assert_equal false, actual, 'scope.enabled?(feature-flag.not-in-seg.segment-or)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for NOT_IN_SEG (segment-or) if one segment rule matches (lookup)
  def test_returns_false_for_not_in_seg_segment_or_if_one_segment_rule_matches_lookup
    client = IntegrationTestHelpers.build_client
    actual = client.enabled?('feature-flag.not-in-seg.segment-or', { 'user' => { 'key' => 'michael' }, '' => { 'domain' => 'example.com' } })
    assert_equal false, actual, 'client.enabled?(feature-flag.not-in-seg.segment-or, { user => { key => michael },  => { domain => example.com } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_BEFORE rule when the given prop represents a date (string) before the rule's time
  def test_returns_true_for_prop_before_rule_when_the_given_prop_represents_a_date_string_before_the_rule_s_time
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'creation_date' => '2024-11-01T00:00:00Z' } })
    actual = scope.enabled?('feature-flag.before')
    assert_equal true, actual, 'scope.enabled?(feature-flag.before)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_BEFORE rule when the given prop represents a date (number) before the rule's time
  def test_returns_true_for_prop_before_rule_when_the_given_prop_represents_a_date_number_before_the_rule_s_time
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'creation_date' => 1_730_419_200_000 } })
    actual = scope.enabled?('feature-flag.before')
    assert_equal true, actual, 'scope.enabled?(feature-flag.before)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_BEFORE rule when the given prop represents a date (number) exactly matching rule's time
  def test_returns_false_for_prop_before_rule_when_the_given_prop_represents_a_date_number_exactly_matching_rule_s_time
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'creation_date' => 1_733_011_200_000 } })
    actual = scope.enabled?('feature-flag.before')
    assert_equal false, actual, 'scope.enabled?(feature-flag.before)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_BEFORE rule when the given prop represents a date (number) AFTER the rule's time
  def test_returns_false_for_prop_before_rule_when_the_given_prop_represents_a_date_number_after_the_rule_s_time
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'creation_date' => '2025-01-01T00:00:00Z' } })
    actual = scope.enabled?('feature-flag.before')
    assert_equal false, actual, 'scope.enabled?(feature-flag.before)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_BEFORE rule when the given prop won't parse as a date
  def test_returns_false_for_prop_before_rule_when_the_given_prop_won_t_parse_as_a_date
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'creation_date' => 'not a date' } })
    actual = scope.enabled?('feature-flag.before')
    assert_equal false, actual, 'scope.enabled?(feature-flag.before)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_BEFORE rule using current-time relative to 2050-01-01
  def test_returns_false_for_prop_before_rule_using_current_time_relative_to_2050_01_01
    client = IntegrationTestHelpers.build_client
    actual = client.enabled?('feature-flag.before.current-time')
    assert_equal true, actual, 'client.enabled?(feature-flag.before.current-time)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_AFTER rule when the given prop represents a date (string) after the rule's time
  def test_returns_true_for_prop_after_rule_when_the_given_prop_represents_a_date_string_after_the_rule_s_time
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'creation_date' => '2025-01-01T00:00:00Z' } })
    actual = scope.enabled?('feature-flag.after')
    assert_equal true, actual, 'scope.enabled?(feature-flag.after)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_AFTER rule when the given prop represents a date (number) after the rule's time
  def test_returns_true_for_prop_after_rule_when_the_given_prop_represents_a_date_number_after_the_rule_s_time
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'creation_date' => 1_735_689_600_000 } })
    actual = scope.enabled?('feature-flag.after')
    assert_equal true, actual, 'scope.enabled?(feature-flag.after)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_AFTER rule when the given prop represents a date (number) exactly matching rule's time
  def test_returns_false_for_prop_after_rule_when_the_given_prop_represents_a_date_number_exactly_matching_rule_s_time
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'creation_date' => 1_733_011_200_000 } })
    actual = scope.enabled?('feature-flag.after')
    assert_equal false, actual, 'scope.enabled?(feature-flag.after)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_BEFORE rule when the given prop represents a date (number) BEFORE the rule's time
  def test_returns_false_for_prop_before_rule_when_the_given_prop_represents_a_date_number_before_the_rule_s_time
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'creation_date' => '2024-01-01T00:00:00Z' } })
    actual = scope.enabled?('feature-flag.after')
    assert_equal false, actual, 'scope.enabled?(feature-flag.after)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_AFTER rule when the given prop won't parse as a date
  def test_returns_false_for_prop_after_rule_when_the_given_prop_won_t_parse_as_a_date
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'creation_date' => 'not a date' } })
    actual = scope.enabled?('feature-flag.after')
    assert_equal false, actual, 'scope.enabled?(feature-flag.after)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_AFTER rule using current-time relative to 2025-01-01
  def test_returns_false_for_prop_after_rule_using_current_time_relative_to_2025_01_01
    client = IntegrationTestHelpers.build_client
    actual = client.enabled?('feature-flag.after.current-time')
    assert_equal true, actual, 'client.enabled?(feature-flag.after.current-time)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_LESS_THAN rule when the given prop is less than the rule's value
  def test_returns_true_for_prop_less_than_rule_when_the_given_prop_is_less_than_the_rule_s_value
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'age' => 20 } })
    actual = scope.enabled?('feature-flag.less-than')
    assert_equal true, actual, 'scope.enabled?(feature-flag.less-than)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_LESS_THAN rule when the given prop is less than the rule's value (float)
  def test_returns_true_for_prop_less_than_rule_when_the_given_prop_is_less_than_the_rule_s_value_float
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'age' => 20.5 } })
    actual = scope.enabled?('feature-flag.less-than')
    assert_equal true, actual, 'scope.enabled?(feature-flag.less-than)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_LESS_THAN rule when the given prop is equal to rule's value
  def test_returns_false_for_prop_less_than_rule_when_the_given_prop_is_equal_to_rule_s_value
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'age' => 30 } })
    actual = scope.enabled?('feature-flag.less-than')
    assert_equal false, actual, 'scope.enabled?(feature-flag.less-than)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_LESS_THAN rule when the given prop a string
  def test_returns_false_for_prop_less_than_rule_when_the_given_prop_a_string
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'age' => '20' } })
    actual = scope.enabled?('feature-flag.less-than')
    assert_equal false, actual, 'scope.enabled?(feature-flag.less-than)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_LESS_THAN_OR_EQUAL rule when the given prop is less than the rule's value
  def test_returns_true_for_prop_less_than_or_equal_rule_when_the_given_prop_is_less_than_the_rule_s_value
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'age' => 20 } })
    actual = scope.enabled?('feature-flag.less-than-or-equal')
    assert_equal true, actual, 'scope.enabled?(feature-flag.less-than-or-equal)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_LESS_THAN_OR_EQUAL rule when the given prop is less than the rule's value (float)
  def test_returns_true_for_prop_less_than_or_equal_rule_when_the_given_prop_is_less_than_the_rule_s_value_float
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'age' => 20.5 } })
    actual = scope.enabled?('feature-flag.less-than-or-equal')
    assert_equal true, actual, 'scope.enabled?(feature-flag.less-than-or-equal)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_LESS_THAN_OR_EQUAL rule when the given prop is equal to rule's value
  def test_returns_false_for_prop_less_than_or_equal_rule_when_the_given_prop_is_equal_to_rule_s_value
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'age' => 30 } })
    actual = scope.enabled?('feature-flag.less-than-or-equal')
    assert_equal true, actual, 'scope.enabled?(feature-flag.less-than-or-equal)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_LESS_THAN_OR_EQUAL rule when the given prop a string
  def test_returns_false_for_prop_less_than_or_equal_rule_when_the_given_prop_a_string
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'age' => '20' } })
    actual = scope.enabled?('feature-flag.less-than-or-equal')
    assert_equal false, actual, 'scope.enabled?(feature-flag.less-than-or-equal)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_GREATER_THAN rule when the given prop is greater than the rule's value
  def test_returns_true_for_prop_greater_than_rule_when_the_given_prop_is_greater_than_the_rule_s_value
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'age' => 100 } })
    actual = scope.enabled?('feature-flag.greater-than')
    assert_equal true, actual, 'scope.enabled?(feature-flag.greater-than)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_GREATER_THAN rule when the given prop is greater than the rule's value (float)
  def test_returns_true_for_prop_greater_than_rule_when_the_given_prop_is_greater_than_the_rule_s_value_float
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'age' => 30.5 } })
    actual = scope.enabled?('feature-flag.greater-than')
    assert_equal true, actual, 'scope.enabled?(feature-flag.greater-than)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_GREATER_THAN rule when the given prop is greater than the rule's float value (float)
  def test_returns_true_for_prop_greater_than_rule_when_the_given_prop_is_greater_than_the_rule_s_float_value_float
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'age' => 32.7 } })
    actual = scope.enabled?('feature-flag.greater-than.double')
    assert_equal true, actual, 'scope.enabled?(feature-flag.greater-than.double)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_GREATER_THAN rule when the given prop is greater than the rule's float value (integer)
  def test_returns_true_for_prop_greater_than_rule_when_the_given_prop_is_greater_than_the_rule_s_float_value_integer
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'age' => 32 } })
    actual = scope.enabled?('feature-flag.greater-than.double')
    assert_equal true, actual, 'scope.enabled?(feature-flag.greater-than.double)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_GREATER_THAN rule when the given prop is equal to rule's value
  def test_returns_false_for_prop_greater_than_rule_when_the_given_prop_is_equal_to_rule_s_value
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'age' => 30 } })
    actual = scope.enabled?('feature-flag.greater-than')
    assert_equal false, actual, 'scope.enabled?(feature-flag.greater-than)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_GREATER_THAN rule when the given prop a string
  def test_returns_false_for_prop_greater_than_rule_when_the_given_prop_a_string
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'age' => '100' } })
    actual = scope.enabled?('feature-flag.greater-than')
    assert_equal false, actual, 'scope.enabled?(feature-flag.greater-than)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_GREATER_THAN_OR_EQUAL rule when the given prop is greater than the rule's value
  def test_returns_true_for_prop_greater_than_or_equal_rule_when_the_given_prop_is_greater_than_the_rule_s_value
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'age' => 30 } })
    actual = scope.enabled?('feature-flag.greater-than-or-equal')
    assert_equal true, actual, 'scope.enabled?(feature-flag.greater-than-or-equal)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_GREATER_THAN_OR_EQUAL rule when the given prop is greater than the rule's value (float)
  def test_returns_true_for_prop_greater_than_or_equal_rule_when_the_given_prop_is_greater_than_the_rule_s_value_float
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'age' => 30.5 } })
    actual = scope.enabled?('feature-flag.greater-than-or-equal')
    assert_equal true, actual, 'scope.enabled?(feature-flag.greater-than-or-equal)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_GREATER_THAN_OR_EQUAL rule when the given prop is equal to rule's value
  def test_returns_true_for_prop_greater_than_or_equal_rule_when_the_given_prop_is_equal_to_rule_s_value
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'age' => 30 } })
    actual = scope.enabled?('feature-flag.greater-than-or-equal')
    assert_equal true, actual, 'scope.enabled?(feature-flag.greater-than-or-equal)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_GREATER_THAN_OR_EQUAL rule when the given prop a string
  def test_returns_false_for_prop_greater_than_or_equal_rule_when_the_given_prop_a_string
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'age' => '100' } })
    actual = scope.enabled?('feature-flag.greater-than-or-equal')
    assert_equal false, actual, 'scope.enabled?(feature-flag.greater-than-or-equal)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_MATCHES rule when the given prop matches the regex
  def test_returns_true_for_prop_matches_rule_when_the_given_prop_matches_the_regex
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'code' => 'aaaaaab' } })
    actual = scope.enabled?('feature-flag.matches')
    assert_equal true, actual, 'scope.enabled?(feature-flag.matches)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_MATCHES rule when the given prop does not match the regex
  def test_returns_false_for_prop_matches_rule_when_the_given_prop_does_not_match_the_regex
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'code' => 'aa' } })
    actual = scope.enabled?('feature-flag.matches')
    assert_equal false, actual, 'scope.enabled?(feature-flag.matches)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_DOES_NOT_MATCH rule when the given prop does not match the regex
  def test_returns_true_for_prop_does_not_match_rule_when_the_given_prop_does_not_match_the_regex
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'code' => 'b' } })
    actual = scope.enabled?('feature-flag.does-not-match')
    assert_equal true, actual, 'scope.enabled?(feature-flag.does-not-match)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_DOES_NOT_MATCH rule when the given prop matches the regex
  def test_returns_false_for_prop_does_not_match_rule_when_the_given_prop_matches_the_regex
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'code' => 'aabb' } })
    actual = scope.enabled?('feature-flag.does-not-match')
    assert_equal false, actual, 'scope.enabled?(feature-flag.does-not-match)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for IS_PRESENT rule when the given prop is a non-empty string
  def test_returns_true_for_is_present_rule_when_the_given_prop_is_a_non_empty_string
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'id' => 'abc' } })
    actual = scope.enabled?('feature-flag.is-present')
    assert_equal true, actual, 'scope.enabled?(feature-flag.is-present)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for IS_PRESENT rule when the given prop is an empty string
  def test_returns_true_for_is_present_rule_when_the_given_prop_is_an_empty_string
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'id' => '' } })
    actual = scope.enabled?('feature-flag.is-present')
    assert_equal true, actual, 'scope.enabled?(feature-flag.is-present)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for IS_PRESENT rule when the given prop is the integer zero
  def test_returns_true_for_is_present_rule_when_the_given_prop_is_the_integer_zero
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'id' => 0 } })
    actual = scope.enabled?('feature-flag.is-present')
    assert_equal true, actual, 'scope.enabled?(feature-flag.is-present)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for IS_PRESENT rule when the given prop is boolean false
  def test_returns_true_for_is_present_rule_when_the_given_prop_is_boolean_false
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'id' => false } })
    actual = scope.enabled?('feature-flag.is-present')
    assert_equal true, actual, 'scope.enabled?(feature-flag.is-present)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for IS_PRESENT rule when the given prop is null
  def test_returns_false_for_is_present_rule_when_the_given_prop_is_null
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'id' => nil } })
    actual = scope.enabled?('feature-flag.is-present')
    assert_equal false, actual, 'scope.enabled?(feature-flag.is-present)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for IS_PRESENT rule when the given prop key is missing from the context
  def test_returns_false_for_is_present_rule_when_the_given_prop_key_is_missing_from_the_context
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'name' => 'bob' } })
    actual = scope.enabled?('feature-flag.is-present')
    assert_equal false, actual, 'scope.enabled?(feature-flag.is-present)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for IS_PRESENT rule when no contexts are provided at all
  def test_returns_false_for_is_present_rule_when_no_contexts_are_provided_at_all
    client = IntegrationTestHelpers.build_client
    actual = client.enabled?('feature-flag.is-present')
    assert_equal false, actual, 'client.enabled?(feature-flag.is-present)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for IS_NOT_PRESENT rule when the given prop is a non-empty string
  def test_returns_false_for_is_not_present_rule_when_the_given_prop_is_a_non_empty_string
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'id' => 'abc' } })
    actual = scope.enabled?('feature-flag.is-not-present')
    assert_equal false, actual, 'scope.enabled?(feature-flag.is-not-present)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for IS_NOT_PRESENT rule when the given prop is null
  def test_returns_true_for_is_not_present_rule_when_the_given_prop_is_null
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'id' => nil } })
    actual = scope.enabled?('feature-flag.is-not-present')
    assert_equal true, actual, 'scope.enabled?(feature-flag.is-not-present)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for IS_NOT_PRESENT rule when the given prop key is missing from the context
  def test_returns_true_for_is_not_present_rule_when_the_given_prop_key_is_missing_from_the_context
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'name' => 'bob' } })
    actual = scope.enabled?('feature-flag.is-not-present')
    assert_equal true, actual, 'scope.enabled?(feature-flag.is-not-present)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for IS_PRESENT rule on a nested path when the nested prop is set
  def test_returns_true_for_is_present_rule_on_a_nested_path_when_the_nested_prop_is_set
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'organization' => { 'domain' => 'example.com' } })
    actual = scope.enabled?('feature-flag.is-present-nested')
    assert_equal true, actual, 'scope.enabled?(feature-flag.is-present-nested)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for IS_PRESENT rule on a nested path when the nested key is missing but the parent context exists
  def test_returns_false_for_is_present_rule_on_a_nested_path_when_the_nested_key_is_missing_but_the_parent_context_exists
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'organization' => { 'name' => 'Acme Inc' } })
    actual = scope.enabled?('feature-flag.is-present-nested')
    assert_equal false, actual, 'scope.enabled?(feature-flag.is-present-nested)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for IS_PRESENT rule on a nested path when the parent context is entirely absent
  def test_returns_false_for_is_present_rule_on_a_nested_path_when_the_parent_context_is_entirely_absent
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'user' => { 'id' => 'abc' } })
    actual = scope.enabled?('feature-flag.is-present-nested')
    assert_equal false, actual, 'scope.enabled?(feature-flag.is-present-nested)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_SEMVER_EQUAL rule when the given prop equals the version
  def test_returns_true_for_prop_semver_equal_rule_when_the_given_prop_equals_the_version
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'app' => { 'version' => '2.0.0' } })
    actual = scope.enabled?('feature-flag.semver-equal')
    assert_equal true, actual, 'scope.enabled?(feature-flag.semver-equal)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_SEMVER_EQUAL rule when the given prop does not equal the version
  def test_returns_false_for_prop_semver_equal_rule_when_the_given_prop_does_not_equal_the_version
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'app' => { 'version' => '2.0.1' } })
    actual = scope.enabled?('feature-flag.semver-equal')
    assert_equal false, actual, 'scope.enabled?(feature-flag.semver-equal)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_SEMVER_EQUAL rule when the given prop is not a valid semver
  def test_returns_false_for_prop_semver_equal_rule_when_the_given_prop_is_not_a_valid_semver
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'app' => { 'version' => '2.0' } })
    actual = scope.enabled?('feature-flag.semver-equal')
    assert_equal false, actual, 'scope.enabled?(feature-flag.semver-equal)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_SEMVER_LESS_THAN rule when the given prop is less than 2.0.0
  def test_returns_true_for_prop_semver_less_than_rule_when_the_given_prop_is_less_than_2_0_0
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'app' => { 'version' => '1.5.1' } })
    actual = scope.enabled?('feature-flag.semver-less-than')
    assert_equal true, actual, 'scope.enabled?(feature-flag.semver-less-than)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_SEMVER_LESS_THAN rule when the given prop equals the version
  def test_returns_false_for_prop_semver_less_than_rule_when_the_given_prop_equals_the_version
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'app' => { 'version' => '2.0.0' } })
    actual = scope.enabled?('feature-flag.semver-less-than')
    assert_equal false, actual, 'scope.enabled?(feature-flag.semver-less-than)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_SEMVER_LESS_THAN rule when the given prop is greater than the version
  def test_returns_false_for_prop_semver_less_than_rule_when_the_given_prop_is_greater_than_the_version
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'app' => { 'version' => '2.2.1' } })
    actual = scope.enabled?('feature-flag.semver-less-than')
    assert_equal false, actual, 'scope.enabled?(feature-flag.semver-less-than)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns true for PROP_SEMVER_GREATER_THAN rule when the given prop is greater than 2.0.0
  def test_returns_true_for_prop_semver_greater_than_rule_when_the_given_prop_is_greater_than_2_0_0
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'app' => { 'version' => '2.5.1' } })
    actual = scope.enabled?('feature-flag.semver-greater-than')
    assert_equal true, actual, 'scope.enabled?(feature-flag.semver-greater-than)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_SEMVER_GREATER_THAN rule when the given prop equals the version
  def test_returns_false_for_prop_semver_greater_than_rule_when_the_given_prop_equals_the_version
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'app' => { 'version' => '2.0.0' } })
    actual = scope.enabled?('feature-flag.semver-greater-than')
    assert_equal false, actual, 'scope.enabled?(feature-flag.semver-greater-than)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # returns false for PROP_SEMVER_EQUAL rule when the given prop is less than the version
  def test_returns_false_for_prop_semver_equal_rule_when_the_given_prop_is_less_than_the_version
    client = IntegrationTestHelpers.build_client
    scope = client.with_context({ 'app' => { 'version' => '0.0.5' } })
    actual = scope.enabled?('feature-flag.semver-greater-than')
    assert_equal false, actual, 'scope.enabled?(feature-flag.semver-greater-than)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end
end
