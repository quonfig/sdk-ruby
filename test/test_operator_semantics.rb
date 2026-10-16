# frozen_string_literal: true

require 'test_helper'

# qfg-goi1.5.7: cross-SDK operator semantics (project/plans/2026-10-07-sdk-operator-semantics.md
# R1, R5, Q5) for the cases the integration-test-data corpus cannot carry.
# The ITD generators read YAML as JS numbers, so 1.0 arrives as the int 1;
# whole-number floats and criterion-side date strings are pinned here.
class TestOperatorSemantics < Minitest::Test
  def evaluate(criterion, context_hash)
    config = {
      id: 'id-1', key: 'ops.key', type: 'config', value_type: 'string', send_to_client_sdk: false,
      default: { 'rules' => [
        { 'criteria' => [criterion], 'value' => { 'type' => 'string', 'value' => 'yes' } },
        { 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }], 'value' => { 'type' => 'string', 'value' => 'no' } }
      ] },
      environment: nil
    }
    store = Quonfig::ConfigStore.new
    store.set(config[:key], config)
    evaluator = Quonfig::Evaluator.new(store)
    Quonfig::Resolver.new(store, evaluator).get(config[:key], Quonfig::Context.new(context_hash)).unwrapped_value
  end

  def list_criterion(operator, values)
    { 'propertyName' => 'user.n', 'operator' => operator,
      'valueToMatch' => { 'type' => 'string_list', 'value' => values } }
  end

  # ------ R1: integral numbers stringify as plain digits ------

  def test_whole_number_floats_match_digit_lists
    [
      [1.0, '1'],
      [1_234_567.0, '1234567'],
      [5e9, '5000000000'],
      [-42.0, '-42'],
      [0.0, '0']
    ].each do |ctx, digits|
      assert_equal 'yes', evaluate(list_criterion('PROP_IS_ONE_OF', [digits]), { user: { n: ctx } }),
                   "#{ctx.inspect} should match [#{digits.inspect}]"
      assert_equal 'no', evaluate(list_criterion('PROP_IS_ONE_OF', ["#{digits}.0"]), { user: { n: ctx } }),
                   "#{ctx.inspect} should not match [\"#{digits}.0\"]"
    end
  end

  def test_whole_number_floats_in_a_context_list
    assert_equal 'yes', evaluate(list_criterion('PROP_IS_ONE_OF', ['7']), { user: { n: [3.0, 7.0] } })
  end

  def test_non_integral_float_keeps_decimal_form
    assert_equal 'yes', evaluate(list_criterion('PROP_IS_ONE_OF', ['1.5']), { user: { n: 1.5 } })
  end

  def test_string_operators_use_canonical_digits
    assert_equal 'yes', evaluate(list_criterion('PROP_ENDS_WITH_ONE_OF', ['567']), { user: { n: 1_234_567.0 } })
    assert_equal 'yes', evaluate(list_criterion('PROP_STARTS_WITH_ONE_OF', ['50000']), { user: { n: 5e9 } })
    assert_equal 'no', evaluate(list_criterion('PROP_CONTAINS_ONE_OF', ['e']), { user: { n: 5e9 } })
  end

  def test_booleans_stringify_lowercase
    assert_equal 'yes', evaluate(list_criterion('PROP_IS_ONE_OF', ['true']), { user: { n: true } })
    assert_equal 'yes', evaluate(list_criterion('PROP_IS_ONE_OF', ['false']), { user: { n: false } })
  end

  # ------ R5: one strict timestamp grammar, both sides ------

  def date_criterion(operator, value, type: 'string')
    { 'propertyName' => 'user.at', 'operator' => operator, 'valueToMatch' => { 'type' => type, 'value' => value } }
  end

  def test_criterion_side_rejects_non_rfc3339_strings
    ['2050-01-01', '2050-01-01T00:00:00', 'Jan 1 2050', '2050-01-01 00:00:00Z', '2050-01-01t00:00:00z',
     '2050-02-30T00:00:00Z', '2050-01-01T24:00:00Z', '0x10', '1_000', ' 1000', ''].each do |bad|
      assert_equal 'no', evaluate(date_criterion('PROP_BEFORE', bad), { user: { at: 1000 } }),
                   "criterion #{bad.inspect} must not parse as a timestamp"
    end
  end

  def test_context_side_rejects_non_rfc3339_strings
    ['2020-01-01', '2020-01-01T00:00:00', 'Jan 1 2020', '0x10', '1_000'].each do |bad|
      assert_equal 'no', evaluate(date_criterion('PROP_BEFORE', '2050-01-01T00:00:00Z'), { user: { at: bad } }),
                   "context #{bad.inspect} must not parse as a timestamp"
    end
  end

  def test_accepted_timestamp_forms
    crit = date_criterion('PROP_BEFORE', '2050-01-01T00:00:00Z')
    [1000, 1000.9, '1730419200000', '-5', '2020-01-01T00:00:00Z', '2020-01-01T09:00:00+09:00',
     '2020-01-01T00:00:00.123456-05:00'].each do |ok|
      assert_equal 'yes', evaluate(crit, { user: { at: ok } }), "context #{ok.inspect} should be before 2050"
    end
    assert_equal 'yes', evaluate(date_criterion('PROP_AFTER', '999'), { user: { at: 1000 } })
    assert_equal 'yes', evaluate(date_criterion('PROP_AFTER', 999, type: 'int'), { user: { at: 1000 } })
  end

  def test_offsets_and_fractions_are_exact
    crit = date_criterion('PROP_AFTER', '2020-01-01T00:00:00Z')
    # 09:00:00.001+09:00 is 00:00:00.001Z: one millisecond after the criterion.
    assert_equal 'yes', evaluate(crit, { user: { at: '2020-01-01T09:00:00.001+09:00' } })
    assert_equal 'no', evaluate(crit, { user: { at: '2020-01-01T09:00:00+09:00' } })
    assert_equal 'no', evaluate(crit, { user: { at: '2020-01-01T00:00:00.0009Z' } })
  end

  def test_non_finite_numbers_never_match
    assert_equal 'no', evaluate(date_criterion('PROP_BEFORE', '2050-01-01T00:00:00Z'), { user: { at: Float::NAN } })
    assert_equal 'no',
                 evaluate(date_criterion('PROP_AFTER', '2020-01-01T00:00:00Z'), { user: { at: Float::INFINITY } })
  end

  # ------ Q5: abbreviated semver ------

  def semver_criterion(operator, value)
    { 'propertyName' => 'app.v', 'operator' => operator, 'valueToMatch' => { 'type' => 'string', 'value' => value } }
  end

  def test_abbreviated_versions_on_both_sides
    assert_equal 'yes', evaluate(semver_criterion('PROP_SEMVER_EQUAL', '2.0.0'), { app: { v: '2' } })
    assert_equal 'yes', evaluate(semver_criterion('PROP_SEMVER_EQUAL', '2.0.0'), { app: { v: '2.0' } })
    assert_equal 'yes', evaluate(semver_criterion('PROP_SEMVER_EQUAL', '4.1'), { app: { v: '4.1.0' } })
    assert_equal 'yes', evaluate(semver_criterion('PROP_SEMVER_GREATER_THAN', '4.1'), { app: { v: '4.1.1' } })
    assert_equal 'yes', evaluate(semver_criterion('PROP_SEMVER_LESS_THAN', '2'), { app: { v: '1.9' } })
  end

  def test_abbreviated_versions_take_no_prerelease_or_prefix
    ['2.0-beta', '2-beta', 'v2', '2.', '02', '2.01'].each do |bad|
      assert_equal 'no', evaluate(semver_criterion('PROP_SEMVER_LESS_THAN', '9.0.0'), { app: { v: bad } }),
                   "#{bad.inspect} is not a version"
    end
  end
end
