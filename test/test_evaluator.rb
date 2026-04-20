# frozen_string_literal: true

require 'test_helper'

# qfg-dk6.10: operator-level tests for Quonfig::Evaluator against the JSON
# Criterion shape (propertyName / operator / valueToMatch). Mirrors sdk-node's
# evaluator behaviour — the node suite is the authoritative spec.
#
# The Evaluator consumes configs in the shape produced by
# IntegrationTestHelpers.to_config_response / Quonfig::Datadir.to_config_response:
#   {
#     id:, key:, type:, value_type:,
#     send_to_client_sdk:, default: { 'rules' => [...] }, environment: {...}
#   }
# Rules/criteria inside stay as plain JSON hashes (string keys), matching what
# lands on disk in integration-test-data.
class TestEvaluator < Minitest::Test
  def build_config(rules, key: 'my.key', value_type: 'string', environment: nil)
    {
      id: 'id-1',
      key: key,
      type: 'config',
      value_type: value_type,
      send_to_client_sdk: false,
      default: { 'rules' => rules },
      environment: environment
    }
  end

  def evaluate(config, context_hash = {}, extra_configs: {})
    store = Quonfig::ConfigStore.new
    store.set(config[:key], config)
    extra_configs.each { |k, v| store.set(k, v) }
    evaluator = Quonfig::Evaluator.new(store)
    resolver = Quonfig::Resolver.new(store, evaluator)
    resolver.get(config[:key], Quonfig::Context.new(context_hash))
  end

  def value_match_rule(criteria, value_type, value)
    {
      'criteria' => criteria,
      'value' => { 'type' => value_type, 'value' => value }
    }
  end

  # ------ ALWAYS_TRUE ------

  def test_always_true
    cfg = build_config([
      value_match_rule([{ 'operator' => 'ALWAYS_TRUE' }], 'string', 'hit')
    ])
    assert_equal 'hit', evaluate(cfg).unwrapped_value
  end

  # ------ PROP_IS_ONE_OF / PROP_IS_NOT_ONE_OF ------

  def test_prop_is_one_of_matches
    cfg = build_config([
      value_match_rule(
        [{ 'propertyName' => 'user.email', 'operator' => 'PROP_IS_ONE_OF',
           'valueToMatch' => { 'type' => 'string_list', 'value' => %w[a@b.com c@d.com] } }],
        'string', 'match'
      ),
      value_match_rule([{ 'operator' => 'ALWAYS_TRUE' }], 'string', 'nope')
    ])
    assert_equal 'match', evaluate(cfg, { user: { email: 'a@b.com' } }).unwrapped_value
    assert_equal 'nope', evaluate(cfg, { user: { email: 'z@z.com' } }).unwrapped_value
  end

  def test_prop_is_not_one_of_inverse
    cfg = build_config([
      value_match_rule(
        [{ 'propertyName' => 'user.email', 'operator' => 'PROP_IS_NOT_ONE_OF',
           'valueToMatch' => { 'type' => 'string_list', 'value' => %w[a@b.com] } }],
        'string', 'match'
      ),
      value_match_rule([{ 'operator' => 'ALWAYS_TRUE' }], 'string', 'nope')
    ])
    # Missing context => NOT_ONE_OF is true (sdk-node parity)
    assert_equal 'match', evaluate(cfg, {}).unwrapped_value
    assert_equal 'nope', evaluate(cfg, { user: { email: 'a@b.com' } }).unwrapped_value
    assert_equal 'match', evaluate(cfg, { user: { email: 'z@z.com' } }).unwrapped_value
  end

  # ------ PROP_STARTS_WITH / ENDS_WITH / CONTAINS ------

  def test_starts_with
    cfg = build_config([
      value_match_rule(
        [{ 'propertyName' => 'user.email', 'operator' => 'PROP_STARTS_WITH_ONE_OF',
           'valueToMatch' => { 'type' => 'string_list', 'value' => %w[admin- root-] } }],
        'string', 'yes'
      ),
      value_match_rule([{ 'operator' => 'ALWAYS_TRUE' }], 'string', 'no')
    ])
    assert_equal 'yes', evaluate(cfg, { user: { email: 'admin-bob' } }).unwrapped_value
    assert_equal 'no', evaluate(cfg, { user: { email: 'bob' } }).unwrapped_value
  end

  def test_ends_with
    cfg = build_config([
      value_match_rule(
        [{ 'propertyName' => 'user.email', 'operator' => 'PROP_ENDS_WITH_ONE_OF',
           'valueToMatch' => { 'type' => 'string_list', 'value' => ['@prefab.cloud'] } }],
        'string', 'yes'
      ),
      value_match_rule([{ 'operator' => 'ALWAYS_TRUE' }], 'string', 'no')
    ])
    assert_equal 'yes', evaluate(cfg, { user: { email: 'b@prefab.cloud' } }).unwrapped_value
    assert_equal 'no', evaluate(cfg, { user: { email: 'b@other.com' } }).unwrapped_value
  end

  def test_contains
    cfg = build_config([
      value_match_rule(
        [{ 'propertyName' => 'user.email', 'operator' => 'PROP_CONTAINS_ONE_OF',
           'valueToMatch' => { 'type' => 'string_list', 'value' => ['admin'] } }],
        'string', 'yes'
      ),
      value_match_rule([{ 'operator' => 'ALWAYS_TRUE' }], 'string', 'no')
    ])
    assert_equal 'yes', evaluate(cfg, { user: { email: 'admin@x.com' } }).unwrapped_value
    assert_equal 'no', evaluate(cfg, { user: { email: 'b@x.com' } }).unwrapped_value
  end

  # ------ PROP_MATCHES / DOES_NOT_MATCH ------

  def test_prop_matches
    cfg = build_config([
      value_match_rule(
        [{ 'propertyName' => 'user.email', 'operator' => 'PROP_MATCHES',
           'valueToMatch' => { 'type' => 'string', 'value' => '^admin' } }],
        'string', 'yes'
      ),
      value_match_rule([{ 'operator' => 'ALWAYS_TRUE' }], 'string', 'no')
    ])
    assert_equal 'yes', evaluate(cfg, { user: { email: 'admin-foo' } }).unwrapped_value
    assert_equal 'no', evaluate(cfg, { user: { email: 'foo' } }).unwrapped_value
  end

  # ------ HIERARCHICAL_MATCH ------

  def test_hierarchical_match
    cfg = build_config([
      value_match_rule(
        [{ 'propertyName' => 'team.path', 'operator' => 'HIERARCHICAL_MATCH',
           'valueToMatch' => { 'type' => 'string', 'value' => 'orgs/a' } }],
        'string', 'yes'
      ),
      value_match_rule([{ 'operator' => 'ALWAYS_TRUE' }], 'string', 'no')
    ])
    assert_equal 'yes', evaluate(cfg, { team: { path: 'orgs/a/team1' } }).unwrapped_value
    assert_equal 'no',  evaluate(cfg, { team: { path: 'orgs/b/team1' } }).unwrapped_value
  end

  # ------ IN_INT_RANGE ------

  def test_in_int_range
    cfg = build_config([
      value_match_rule(
        [{ 'propertyName' => 'user.age', 'operator' => 'IN_INT_RANGE',
           'valueToMatch' => { 'type' => 'int_range', 'value' => { 'start' => 18, 'end' => 30 } } }],
        'string', 'yes'
      ),
      value_match_rule([{ 'operator' => 'ALWAYS_TRUE' }], 'string', 'no')
    ])
    assert_equal 'yes', evaluate(cfg, { user: { age: 20 } }).unwrapped_value
    assert_equal 'no',  evaluate(cfg, { user: { age: 30 } }).unwrapped_value  # end exclusive
    assert_equal 'yes', evaluate(cfg, { user: { age: 18 } }).unwrapped_value  # start inclusive
  end

  # ------ NUMERIC COMPARISONS ------

  def test_prop_greater_than_lt_etc
    %w[PROP_GREATER_THAN PROP_GREATER_THAN_OR_EQUAL PROP_LESS_THAN PROP_LESS_THAN_OR_EQUAL].each do |op|
      cfg = build_config([
        value_match_rule(
          [{ 'propertyName' => 'user.age', 'operator' => op,
             'valueToMatch' => { 'type' => 'int', 'value' => 10 } }],
          'string', 'yes'
        ),
        value_match_rule([{ 'operator' => 'ALWAYS_TRUE' }], 'string', 'no')
      ])
      expected = case op
                 when 'PROP_GREATER_THAN' then { 9 => 'no', 10 => 'no', 11 => 'yes' }
                 when 'PROP_GREATER_THAN_OR_EQUAL' then { 9 => 'no', 10 => 'yes', 11 => 'yes' }
                 when 'PROP_LESS_THAN' then { 9 => 'yes', 10 => 'no', 11 => 'no' }
                 when 'PROP_LESS_THAN_OR_EQUAL' then { 9 => 'yes', 10 => 'yes', 11 => 'no' }
                 end
      expected.each do |age, want|
        assert_equal want, evaluate(cfg, { user: { age: age } }).unwrapped_value,
                     "op=#{op} age=#{age}"
      end
    end
  end

  # ------ DATE COMPARISONS (BEFORE / AFTER) ------

  def test_prop_before_after
    cfg_before = build_config([
      value_match_rule(
        [{ 'propertyName' => 'user.created_at', 'operator' => 'PROP_BEFORE',
           'valueToMatch' => { 'type' => 'string', 'value' => '2025-01-01T00:00:00Z' } }],
        'string', 'yes'
      ),
      value_match_rule([{ 'operator' => 'ALWAYS_TRUE' }], 'string', 'no')
    ])
    assert_equal 'yes', evaluate(cfg_before, { user: { created_at: '2024-06-01T00:00:00Z' } }).unwrapped_value
    assert_equal 'no',  evaluate(cfg_before, { user: { created_at: '2025-06-01T00:00:00Z' } }).unwrapped_value
  end

  # ------ SEMVER COMPARISONS ------

  def test_semver_eq_gt_lt
    [
      ['PROP_SEMVER_EQUAL',        '1.2.3', '1.2.3', 'yes'],
      ['PROP_SEMVER_EQUAL',        '1.2.4', '1.2.3', 'no'],
      ['PROP_SEMVER_GREATER_THAN', '1.2.4', '1.2.3', 'yes'],
      ['PROP_SEMVER_GREATER_THAN', '1.2.3', '1.2.4', 'no'],
      ['PROP_SEMVER_LESS_THAN',    '1.2.2', '1.2.3', 'yes'],
      ['PROP_SEMVER_LESS_THAN',    '1.2.4', '1.2.3', 'no']
    ].each do |op, context_ver, match_ver, want|
      cfg = build_config([
        value_match_rule(
          [{ 'propertyName' => 'app.version', 'operator' => op,
             'valueToMatch' => { 'type' => 'string', 'value' => match_ver } }],
          'string', 'yes'
        ),
        value_match_rule([{ 'operator' => 'ALWAYS_TRUE' }], 'string', 'no')
      ])
      assert_equal want, evaluate(cfg, { app: { version: context_ver } }).unwrapped_value,
                   "op=#{op} ctx=#{context_ver} match=#{match_ver}"
    end
  end

  # ------ IN_SEG / NOT_IN_SEG ------

  def test_in_seg_resolves_via_store
    segment = build_config([
      value_match_rule(
        [{ 'propertyName' => 'user.email', 'operator' => 'PROP_IS_ONE_OF',
           'valueToMatch' => { 'type' => 'string_list', 'value' => ['ok@x.com'] } }],
        'bool', true
      ),
      value_match_rule([{ 'operator' => 'ALWAYS_TRUE' }], 'bool', false)
    ], key: 'seg.key', value_type: 'bool')

    cfg = build_config([
      value_match_rule(
        [{ 'propertyName' => '', 'operator' => 'IN_SEG',
           'valueToMatch' => { 'type' => 'string', 'value' => 'seg.key' } }],
        'string', 'in'
      ),
      value_match_rule([{ 'operator' => 'ALWAYS_TRUE' }], 'string', 'out')
    ])

    extra = { 'seg.key' => segment }
    assert_equal 'in',  evaluate(cfg, { user: { email: 'ok@x.com' } }, extra_configs: extra).unwrapped_value
    assert_equal 'out', evaluate(cfg, { user: { email: 'no@x.com' } }, extra_configs: extra).unwrapped_value
  end

  # ------ ENVIRONMENT-SPECIFIC RULES ------

  def test_environment_rules_precede_default
    env_rule = value_match_rule(
      [{ 'operator' => 'ALWAYS_TRUE' }], 'string', 'from-env'
    )
    default_rule = value_match_rule(
      [{ 'operator' => 'ALWAYS_TRUE' }], 'string', 'from-default'
    )
    cfg = build_config(
      [default_rule],
      environment: { 'id' => 'Production', 'rules' => [env_rule] }
    )
    # default evaluator has no envID set, so falls back to default rules
    assert_equal 'from-default', evaluate(cfg).unwrapped_value

    store = Quonfig::ConfigStore.new
    store.set(cfg[:key], cfg)
    evaluator = Quonfig::Evaluator.new(store, env_id: 'Production')
    resolver = Quonfig::Resolver.new(store, evaluator)
    result = resolver.get(cfg[:key], Quonfig::Context.new({}))
    assert_equal 'from-env', result.unwrapped_value
  end
end
