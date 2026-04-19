# frozen_string_literal: true

require 'minitest/autorun'
require 'quonfig/reason'

# Tests Quonfig::Reason in isolation — uses plain Structs so the test does not
# depend on PrefabProto (which is not loaded by the current bootstrap).
class TestReason < Minitest::Test
  FakeCriterion = Struct.new(:operator)
  FakeConditionalValue = Struct.new(:criteria)
  FakeRow = Struct.new(:values, :project_env_id)
  FakeConfig = Struct.new(:rows)

  ALWAYS_TRUE = FakeCriterion.new(:ALWAYS_TRUE)
  PROP_MATCH = FakeCriterion.new(:PROP_IS_ONE_OF)

  DEFAULT_CV = FakeConditionalValue.new([])
  ALWAYS_TRUE_CV = FakeConditionalValue.new([ALWAYS_TRUE])
  RULE_CV = FakeConditionalValue.new([PROP_MATCH])

  def default_only_config
    FakeConfig.new([FakeRow.new([DEFAULT_CV], 0)])
  end

  def targeted_config
    FakeConfig.new([
      FakeRow.new([DEFAULT_CV], 0),
      FakeRow.new([RULE_CV, ALWAYS_TRUE_CV], 1)
    ])
  end

  def test_default_for_default_only_config
    reason = Quonfig::Reason.compute(
      config: default_only_config,
      conditional_value: DEFAULT_CV
    )
    assert_equal :DEFAULT, reason
  end

  def test_rule_match_when_targeting_rule_matched
    reason = Quonfig::Reason.compute(
      config: targeted_config,
      conditional_value: RULE_CV
    )
    assert_equal :RULE_MATCH, reason
  end

  def test_rule_match_when_falling_back_to_always_true_in_targeted_config
    reason = Quonfig::Reason.compute(
      config: targeted_config,
      conditional_value: ALWAYS_TRUE_CV
    )
    assert_equal :RULE_MATCH, reason
  end

  def test_split_when_weighted_value_index_positive
    reason = Quonfig::Reason.compute(
      config: default_only_config,
      conditional_value: DEFAULT_CV,
      weighted_value_index: 2
    )
    assert_equal :SPLIT, reason
  end

  def test_weighted_value_index_zero_is_not_split
    reason = Quonfig::Reason.compute(
      config: default_only_config,
      conditional_value: DEFAULT_CV,
      weighted_value_index: 0
    )
    assert_equal :DEFAULT, reason
  end

  def test_default_when_only_always_true_criteria_and_no_targeting_rules
    config = FakeConfig.new([FakeRow.new([ALWAYS_TRUE_CV], 0)])
    reason = Quonfig::Reason.compute(config: config, conditional_value: ALWAYS_TRUE_CV)
    assert_equal :DEFAULT, reason
  end
end
