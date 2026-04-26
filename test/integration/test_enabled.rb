# frozen_string_literal: true
#
# AUTO-GENERATED from integration-test-data/tests/eval/enabled.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestEnabled < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store("enabled")
  end

  # returns the correct value for a simple flag
  def test_returns_the_correct_value_for_a_simple_flag
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.simple", {}, true)
  end

  # always returns false for a non-boolean flag
  def test_always_returns_false_for_a_non_boolean_flag
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.integer", {}, false)
  end

  # returns true for a PROP_IS_ONE_OF rule when any prop matches
  def test_returns_true_for_a_prop_is_one_of_rule_when_any_prop_matches
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.properties.positive", {"" => {"name" => "michael", "domain" => "something.com"}}, true)
  end

  # returns false for a PROP_IS_ONE_OF rule when no prop matches
  def test_returns_false_for_a_prop_is_one_of_rule_when_no_prop_matches
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.properties.positive", {"" => {"name" => "lauren", "domain" => "something.com"}}, false)
  end

  # returns true for a PROP_IS_NOT_ONE_OF rule when any prop doesn't match
  def test_returns_true_for_a_prop_is_not_one_of_rule_when_any_prop_doesn_t_match
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.properties.negative", {"" => {"name" => "lauren", "domain" => "prefab.cloud"}}, true)
  end

  # returns false for a PROP_IS_NOT_ONE_OF rule when all props match
  def test_returns_false_for_a_prop_is_not_one_of_rule_when_all_props_match
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.properties.negative", {"" => {"name" => "michael", "domain" => "prefab.cloud"}}, false)
  end

  # returns true for PROP_ENDS_WITH_ONE_OF rule when the given prop has a matching suffix
  def test_returns_true_for_prop_ends_with_one_of_rule_when_the_given_prop_has_a_matching_suffix
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.ends-with-one-of.positive", {"" => {"email" => "jeff@prefab.cloud"}}, true)
  end

  # returns false for PROP_ENDS_WITH_ONE_OF rule when the given prop doesn't have a matching suffix
  def test_returns_false_for_prop_ends_with_one_of_rule_when_the_given_prop_doesn_t_have_a_matching_suffix
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.ends-with-one-of.positive", {"" => {"email" => "jeff@test.com"}}, false)
  end

  # returns true for PROP_DOES_NOT_END_WITH_ONE_OF rule when the given prop doesn't have a matching suffix
  def test_returns_true_for_prop_does_not_end_with_one_of_rule_when_the_given_prop_doesn_t_have_a_matching_suffix
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.ends-with-one-of.negative", {"" => {"email" => "michael@test.com"}}, true)
  end

  # returns false for PROP_DOES_NOT_END_WITH_ONE_OF rule when the given prop has a matching suffix
  def test_returns_false_for_prop_does_not_end_with_one_of_rule_when_the_given_prop_has_a_matching_suffix
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.ends-with-one-of.negative", {"" => {"email" => "michael@prefab.cloud"}}, false)
  end

  # returns true for PROP_STARTS_WITH_ONE_OF rule when the given prop has a matching prefix
  def test_returns_true_for_prop_starts_with_one_of_rule_when_the_given_prop_has_a_matching_prefix
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.starts-with-one-of.positive", {"user" => {"email" => "foo@prefab.cloud"}}, true)
  end

  # returns false for PROP_STARTS_WITH_ONE_OF rule when the given prop doesn't have a matching prefix
  def test_returns_false_for_prop_starts_with_one_of_rule_when_the_given_prop_doesn_t_have_a_matching_prefix
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.starts-with-one-of.positive", {"user" => {"email" => "notfoo@prefab.cloud"}}, false)
  end

  # returns true for PROP_DOES_NOT_START_WITH_ONE_OF rule when the given prop doesn't have a matching prefix
  def test_returns_true_for_prop_does_not_start_with_one_of_rule_when_the_given_prop_doesn_t_have_a_matching_prefix
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.starts-with-one-of.negative", {"user" => {"email" => "notfoo@prefab.cloud"}}, true)
  end

  # returns false for PROP_DOES_NOT_START_WITH_ONE_OF rule when the given prop has a matching prefix
  def test_returns_false_for_prop_does_not_start_with_one_of_rule_when_the_given_prop_has_a_matching_prefix
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.starts-with-one-of.negative", {"user" => {"email" => "foo@prefab.cloud"}}, false)
  end

  # returns true for PROP_CONTAINS_ONE_OF rule when the given prop has a matching substring
  def test_returns_true_for_prop_contains_one_of_rule_when_the_given_prop_has_a_matching_substring
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.contains-one-of.positive", {"user" => {"email" => "somefoo@prefab.cloud"}}, true)
  end

  # returns false for PROP_CONTAINS_ONE_OF rule when the given prop doesn't have a matching substring
  def test_returns_false_for_prop_contains_one_of_rule_when_the_given_prop_doesn_t_have_a_matching_substring
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.contains-one-of.positive", {"user" => {"email" => "info@prefab.cloud"}}, false)
  end

  # returns true for PROP_DOES_NOT_CONTAIN_ONE_OF rule when the given prop doesn't have a matching substring
  def test_returns_true_for_prop_does_not_contain_one_of_rule_when_the_given_prop_doesn_t_have_a_matching_substring
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.contains-one-of.negative", {"user" => {"email" => "info@prefab.cloud"}}, true)
  end

  # returns false for PROP_DOES_NOT_CONTAIN_ONE_OF rule when the given prop has a matching substring
  def test_returns_false_for_prop_does_not_contain_one_of_rule_when_the_given_prop_has_a_matching_substring
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.contains-one-of.negative", {"user" => {"email" => "notfoo@prefab.cloud"}}, false)
  end

  # returns true for IN_SEG when the segment rule matches
  def test_returns_true_for_in_seg_when_the_segment_rule_matches
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.in-segment.positive", {"user" => {"key" => "lauren"}}, true)
  end

  # returns false for IN_SEG when the segment rule doesn't match
  def test_returns_false_for_in_seg_when_the_segment_rule_doesn_t_match
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.in-segment.positive", {"user" => {"key" => "josh"}}, false)
  end

  # returns false for IN_SEG if any segment rule fails to match
  def test_returns_false_for_in_seg_if_any_segment_rule_fails_to_match
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.in-seg.segment-and", {"user" => {"key" => "josh"}, "" => {"domain" => "prefab.cloud"}}, false)
  end

  # returns true for IN_SEG (segment-and) if all rules matches
  def test_returns_true_for_in_seg_segment_and_if_all_rules_matches
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.in-seg.segment-and", {"user" => {"key" => "michael"}, "" => {"domain" => "prefab.cloud"}}, true)
  end

  # returns true for IN_SEG (segment-or) if any segment rule matches (lookup)
  def test_returns_true_for_in_seg_segment_or_if_any_segment_rule_matches_lookup
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.in-seg.segment-or", {"user" => {"key" => "michael"}, "" => {"domain" => "example.com"}}, true)
  end

  # returns true for IN_SEG (segment-or) if any segment rule matches (prop)
  def test_returns_true_for_in_seg_segment_or_if_any_segment_rule_matches_prop
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.in-seg.segment-or", {"user" => {"key" => "nobody"}, "" => {"domain" => "gmail.com"}}, true)
  end

  # returns true for NOT_IN_SEG when the segment rule doesn't match
  def test_returns_true_for_not_in_seg_when_the_segment_rule_doesn_t_match
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.in-segment.negative", {"user" => {"key" => "josh"}}, true)
  end

  # returns false for NOT_IN_SEG when the segment rule matches
  def test_returns_false_for_not_in_seg_when_the_segment_rule_matches
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.in-segment.negative", {"user" => {"key" => "michael"}}, false)
  end

  # returns false for NOT_IN_SEG if any segment rule matches
  def test_returns_false_for_not_in_seg_if_any_segment_rule_matches
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.in-segment.multiple-criteria.negative", {"user" => {"key" => "josh"}, "" => {"domain" => "prefab.cloud"}}, true)
  end

  # returns true for NOT_IN_SEG if no segment rule matches
  def test_returns_true_for_not_in_seg_if_no_segment_rule_matches
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.in-segment.multiple-criteria.negative", {"user" => {"key" => "josh"}, "" => {"domain" => "something.com"}}, true)
  end

  # returns true for NOT_IN_SEG (segment-and) if not segment rule fails to match
  def test_returns_true_for_not_in_seg_segment_and_if_not_segment_rule_fails_to_match
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.not-in-seg.segment-and", {"user" => {"key" => "josh"}, "" => {"domain" => "prefab.cloud"}}, true)
  end

  # returns true for IN_SEG (segment-and) if not segment rule fails to match
  def test_returns_true_for_in_seg_segment_and_if_not_segment_rule_fails_to_match
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.in-seg.segment-and", {"user" => {"key" => "josh"}, "" => {"domain" => "prefab.cloud"}}, false)
  end

  # returns false for NOT_IN_SEG (segment-and) if segment rules matches
  def test_returns_false_for_not_in_seg_segment_and_if_segment_rules_matches
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.not-in-seg.segment-and", {"user" => {"key" => "michael"}, "" => {"domain" => "prefab.cloud"}}, false)
  end

  # returns true for NOT_IN_SEG (segment-or) if no segment rule matches
  def test_returns_true_for_not_in_seg_segment_or_if_no_segment_rule_matches
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.not-in-seg.segment-or", {"user" => {"key" => "nobody"}, "" => {"domain" => "example.com"}}, true)
  end

  # returns false for NOT_IN_SEG (segment-or) if one segment rule matches (prop)
  def test_returns_false_for_not_in_seg_segment_or_if_one_segment_rule_matches_prop
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.not-in-seg.segment-or", {"user" => {"key" => "nobody"}, "" => {"domain" => "gmail.com"}}, false)
  end

  # returns false for NOT_IN_SEG (segment-or) if one segment rule matches (lookup)
  def test_returns_false_for_not_in_seg_segment_or_if_one_segment_rule_matches_lookup
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.not-in-seg.segment-or", {"user" => {"key" => "michael"}, "" => {"domain" => "example.com"}}, false)
  end

  # returns true for PROP_BEFORE rule when the given prop represents a date (string) before the rule's time
  def test_returns_true_for_prop_before_rule_when_the_given_prop_represents_a_date_string_before_the_rule_s_time
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.before", {"user" => {"creation_date" => "2024-11-01T00:00:00Z"}}, true)
  end

  # returns true for PROP_BEFORE rule when the given prop represents a date (number) before the rule's time
  def test_returns_true_for_prop_before_rule_when_the_given_prop_represents_a_date_number_before_the_rule_s_time
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.before", {"user" => {"creation_date" => 1730419200000}}, true)
  end

  # returns false for PROP_BEFORE rule when the given prop represents a date (number) exactly matching rule's time
  def test_returns_false_for_prop_before_rule_when_the_given_prop_represents_a_date_number_exactly_matching_rule_s_time
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.before", {"user" => {"creation_date" => 1733011200000}}, false)
  end

  # returns false for PROP_BEFORE rule when the given prop represents a date (number) AFTER the rule's time
  def test_returns_false_for_prop_before_rule_when_the_given_prop_represents_a_date_number_after_the_rule_s_time
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.before", {"user" => {"creation_date" => "2025-01-01T00:00:00Z"}}, false)
  end

  # returns false for PROP_BEFORE rule when the given prop won't parse as a date
  def test_returns_false_for_prop_before_rule_when_the_given_prop_won_t_parse_as_a_date
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.before", {"user" => {"creation_date" => "not a date"}}, false)
  end

  # returns false for PROP_BEFORE rule using current-time relative to 2050-01-01
  def test_returns_false_for_prop_before_rule_using_current_time_relative_to_2050_01_01
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.before.current-time", {}, true)
  end

  # returns true for PROP_AFTER rule when the given prop represents a date (string) after the rule's time
  def test_returns_true_for_prop_after_rule_when_the_given_prop_represents_a_date_string_after_the_rule_s_time
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.after", {"user" => {"creation_date" => "2025-01-01T00:00:00Z"}}, true)
  end

  # returns true for PROP_AFTER rule when the given prop represents a date (number) after the rule's time
  def test_returns_true_for_prop_after_rule_when_the_given_prop_represents_a_date_number_after_the_rule_s_time
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.after", {"user" => {"creation_date" => 1735689600000}}, true)
  end

  # returns false for PROP_AFTER rule when the given prop represents a date (number) exactly matching rule's time
  def test_returns_false_for_prop_after_rule_when_the_given_prop_represents_a_date_number_exactly_matching_rule_s_time
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.after", {"user" => {"creation_date" => 1733011200000}}, false)
  end

  # returns false for PROP_BEFORE rule when the given prop represents a date (number) BEFORE the rule's time
  def test_returns_false_for_prop_before_rule_when_the_given_prop_represents_a_date_number_before_the_rule_s_time
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.after", {"user" => {"creation_date" => "2024-01-01T00:00:00Z"}}, false)
  end

  # returns false for PROP_AFTER rule when the given prop won't parse as a date
  def test_returns_false_for_prop_after_rule_when_the_given_prop_won_t_parse_as_a_date
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.after", {"user" => {"creation_date" => "not a date"}}, false)
  end

  # returns false for PROP_AFTER rule using current-time relative to 2025-01-01
  def test_returns_false_for_prop_after_rule_using_current_time_relative_to_2025_01_01
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.after.current-time", {}, true)
  end

  # returns true for PROP_LESS_THAN rule when the given prop is less than the rule's value
  def test_returns_true_for_prop_less_than_rule_when_the_given_prop_is_less_than_the_rule_s_value
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.less-than", {"user" => {"age" => 20}}, true)
  end

  # returns true for PROP_LESS_THAN rule when the given prop is less than the rule's value (float)
  def test_returns_true_for_prop_less_than_rule_when_the_given_prop_is_less_than_the_rule_s_value_float
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.less-than", {"user" => {"age" => 20.5}}, true)
  end

  # returns false for PROP_LESS_THAN rule when the given prop is equal to rule's value
  def test_returns_false_for_prop_less_than_rule_when_the_given_prop_is_equal_to_rule_s_value
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.less-than", {"user" => {"age" => 30}}, false)
  end

  # returns false for PROP_LESS_THAN rule when the given prop a string
  def test_returns_false_for_prop_less_than_rule_when_the_given_prop_a_string
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.less-than", {"user" => {"age" => "20"}}, false)
  end

  # returns true for PROP_LESS_THAN_OR_EQUAL rule when the given prop is less than the rule's value
  def test_returns_true_for_prop_less_than_or_equal_rule_when_the_given_prop_is_less_than_the_rule_s_value
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.less-than-or-equal", {"user" => {"age" => 20}}, true)
  end

  # returns true for PROP_LESS_THAN_OR_EQUAL rule when the given prop is less than the rule's value (float)
  def test_returns_true_for_prop_less_than_or_equal_rule_when_the_given_prop_is_less_than_the_rule_s_value_float
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.less-than-or-equal", {"user" => {"age" => 20.5}}, true)
  end

  # returns false for PROP_LESS_THAN_OR_EQUAL rule when the given prop is equal to rule's value
  def test_returns_false_for_prop_less_than_or_equal_rule_when_the_given_prop_is_equal_to_rule_s_value
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.less-than-or-equal", {"user" => {"age" => 30}}, true)
  end

  # returns false for PROP_LESS_THAN_OR_EQUAL rule when the given prop a string
  def test_returns_false_for_prop_less_than_or_equal_rule_when_the_given_prop_a_string
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.less-than-or-equal", {"user" => {"age" => "20"}}, false)
  end

  # returns true for PROP_GREATER_THAN rule when the given prop is greater than the rule's value
  def test_returns_true_for_prop_greater_than_rule_when_the_given_prop_is_greater_than_the_rule_s_value
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.greater-than", {"user" => {"age" => 100}}, true)
  end

  # returns true for PROP_GREATER_THAN rule when the given prop is greater than the rule's value (float)
  def test_returns_true_for_prop_greater_than_rule_when_the_given_prop_is_greater_than_the_rule_s_value_float
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.greater-than", {"user" => {"age" => 30.5}}, true)
  end

  # returns true for PROP_GREATER_THAN rule when the given prop is greater than the rule's float value (float)
  def test_returns_true_for_prop_greater_than_rule_when_the_given_prop_is_greater_than_the_rule_s_float_value_float
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.greater-than.double", {"user" => {"age" => 32.7}}, true)
  end

  # returns true for PROP_GREATER_THAN rule when the given prop is greater than the rule's float value (integer)
  def test_returns_true_for_prop_greater_than_rule_when_the_given_prop_is_greater_than_the_rule_s_float_value_integer
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.greater-than.double", {"user" => {"age" => 32}}, true)
  end

  # returns false for PROP_GREATER_THAN rule when the given prop is equal to rule's value
  def test_returns_false_for_prop_greater_than_rule_when_the_given_prop_is_equal_to_rule_s_value
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.greater-than", {"user" => {"age" => 30}}, false)
  end

  # returns false for PROP_GREATER_THAN rule when the given prop a string
  def test_returns_false_for_prop_greater_than_rule_when_the_given_prop_a_string
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.greater-than", {"user" => {"age" => "100"}}, false)
  end

  # returns true for PROP_GREATER_THAN_OR_EQUAL rule when the given prop is greater than the rule's value
  def test_returns_true_for_prop_greater_than_or_equal_rule_when_the_given_prop_is_greater_than_the_rule_s_value
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.greater-than-or-equal", {"user" => {"age" => 30}}, true)
  end

  # returns true for PROP_GREATER_THAN_OR_EQUAL rule when the given prop is greater than the rule's value (float)
  def test_returns_true_for_prop_greater_than_or_equal_rule_when_the_given_prop_is_greater_than_the_rule_s_value_float
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.greater-than-or-equal", {"user" => {"age" => 30.5}}, true)
  end

  # returns true for PROP_GREATER_THAN_OR_EQUAL rule when the given prop is equal to rule's value
  def test_returns_true_for_prop_greater_than_or_equal_rule_when_the_given_prop_is_equal_to_rule_s_value
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.greater-than-or-equal", {"user" => {"age" => 30}}, true)
  end

  # returns false for PROP_GREATER_THAN_OR_EQUAL rule when the given prop a string
  def test_returns_false_for_prop_greater_than_or_equal_rule_when_the_given_prop_a_string
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.greater-than-or-equal", {"user" => {"age" => "100"}}, false)
  end

  # returns true for PROP_MATCHES rule when the given prop matches the regex
  def test_returns_true_for_prop_matches_rule_when_the_given_prop_matches_the_regex
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.matches", {"user" => {"code" => "aaaaaab"}}, true)
  end

  # returns false for PROP_MATCHES rule when the given prop does not match the regex
  def test_returns_false_for_prop_matches_rule_when_the_given_prop_does_not_match_the_regex
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.matches", {"user" => {"code" => "aa"}}, false)
  end

  # returns true for PROP_DOES_NOT_MATCH rule when the given prop does not match the regex
  def test_returns_true_for_prop_does_not_match_rule_when_the_given_prop_does_not_match_the_regex
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.does-not-match", {"user" => {"code" => "b"}}, true)
  end

  # returns false for PROP_DOES_NOT_MATCH rule when the given prop matches the regex
  def test_returns_false_for_prop_does_not_match_rule_when_the_given_prop_matches_the_regex
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.does-not-match", {"user" => {"code" => "aabb"}}, false)
  end

  # returns true for PROP_SEMVER_EQUAL rule when the given prop equals the version
  def test_returns_true_for_prop_semver_equal_rule_when_the_given_prop_equals_the_version
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.semver-equal", {"app" => {"version" => "2.0.0"}}, true)
  end

  # returns false for PROP_SEMVER_EQUAL rule when the given prop does not equal the version
  def test_returns_false_for_prop_semver_equal_rule_when_the_given_prop_does_not_equal_the_version
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.semver-equal", {"app" => {"version" => "2.0.1"}}, false)
  end

  # returns false for PROP_SEMVER_EQUAL rule when the given prop is not a valid semver
  def test_returns_false_for_prop_semver_equal_rule_when_the_given_prop_is_not_a_valid_semver
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.semver-equal", {"app" => {"version" => "2.0"}}, false)
  end

  # returns true for PROP_SEMVER_LESS_THAN rule when the given prop is less than 2.0.0
  def test_returns_true_for_prop_semver_less_than_rule_when_the_given_prop_is_less_than_2_0_0
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.semver-less-than", {"app" => {"version" => "1.5.1"}}, true)
  end

  # returns false for PROP_SEMVER_LESS_THAN rule when the given prop equals the version
  def test_returns_false_for_prop_semver_less_than_rule_when_the_given_prop_equals_the_version
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.semver-less-than", {"app" => {"version" => "2.0.0"}}, false)
  end

  # returns false for PROP_SEMVER_LESS_THAN rule when the given prop is greater than the version
  def test_returns_false_for_prop_semver_less_than_rule_when_the_given_prop_is_greater_than_the_version
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.semver-less-than", {"app" => {"version" => "2.2.1"}}, false)
  end

  # returns true for PROP_SEMVER_GREATER_THAN rule when the given prop is greater than 2.0.0
  def test_returns_true_for_prop_semver_greater_than_rule_when_the_given_prop_is_greater_than_2_0_0
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.semver-greater-than", {"app" => {"version" => "2.5.1"}}, true)
  end

  # returns false for PROP_SEMVER_GREATER_THAN rule when the given prop equals the version
  def test_returns_false_for_prop_semver_greater_than_rule_when_the_given_prop_equals_the_version
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.semver-greater-than", {"app" => {"version" => "2.0.0"}}, false)
  end

  # returns false for PROP_SEMVER_EQUAL rule when the given prop is less than the version
  def test_returns_false_for_prop_semver_equal_rule_when_the_given_prop_is_less_than_the_version
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.semver-greater-than", {"app" => {"version" => "0.0.5"}}, false)
  end
end
