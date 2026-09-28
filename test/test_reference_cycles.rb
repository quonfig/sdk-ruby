# frozen_string_literal: true

require 'test_helper'

# qfg-9dxb.7: reference cycles in stored configs must not recurse until
# SystemStackError (which `rescue => e` / `rescue StandardError` cannot catch).
# Semantics match sdk-go (qfg-9dxb.4):
# - IN_SEG / NOT_IN_SEG cycle -> treated as a MISSING segment
#   (IN_SEG false, NOT_IN_SEG true).
# - decryptWith cycle -> a decryption error, like any other decryption failure.
class TestReferenceCycles < Minitest::Test
  def config(key, rules, value_type: 'string')
    {
      id: key, key: key, type: 'config', value_type: value_type,
      send_to_client_sdk: false, default: { 'rules' => rules }, environment: nil
    }
  end

  def seg_rule(op, seg_key, value, type: 'bool')
    {
      'criteria' => [{ 'propertyName' => '', 'operator' => op,
                       'valueToMatch' => { 'type' => 'string', 'value' => seg_key } }],
      'value' => { 'type' => type, 'value' => value }
    }
  end

  def always(value, type: 'bool')
    { 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }], 'value' => { 'type' => type, 'value' => value } }
  end

  def resolver_for(*configs)
    store = Quonfig::ConfigStore.new
    configs.each { |c| store.set(c[:key], c) }
    Quonfig::Resolver.new(store, Quonfig::Evaluator.new(store))
  end

  def flag_on(seg_key, op)
    config('the.flag', [seg_rule(op, seg_key, 'hit', type: 'string'), always('miss', type: 'string')])
  end

  # --- segments ---------------------------------------------------------

  def test_self_referencing_segment_is_treated_as_missing
    seg = config('seg.a', [seg_rule('IN_SEG', 'seg.a', true), always(false)], value_type: 'bool')
    assert_equal 'miss', resolver_for(seg, flag_on('seg.a', 'IN_SEG')).get('the.flag', {}).unwrapped_value

    seg_not = config('seg.a', [seg_rule('NOT_IN_SEG', 'seg.a', true), always(false)], value_type: 'bool')
    # Inside seg.a, NOT_IN_SEG seg.a is a cycle -> true, so seg.a matches -> the flag's IN_SEG hits.
    assert_equal 'hit', resolver_for(seg_not, flag_on('seg.a', 'IN_SEG')).get('the.flag', {}).unwrapped_value
  end

  def test_two_hop_segment_cycle_is_treated_as_missing
    a = config('seg.a', [seg_rule('IN_SEG', 'seg.b', true), always(false)], value_type: 'bool')
    b = config('seg.b', [seg_rule('IN_SEG', 'seg.a', true), always(false)], value_type: 'bool')
    r = resolver_for(a, b, flag_on('seg.a', 'IN_SEG'))
    assert_equal 'miss', r.get('the.flag', {}).unwrapped_value

    r_not = resolver_for(a, b, flag_on('seg.a', 'NOT_IN_SEG'))
    assert_equal 'hit', r_not.get('the.flag', {}).unwrapped_value
  end

  def test_segment_diamond_still_resolves
    c = config('seg.c', [always(true)], value_type: 'bool')
    a = config('seg.a', [seg_rule('IN_SEG', 'seg.c', true), always(false)], value_type: 'bool')
    b = config('seg.b', [seg_rule('IN_SEG', 'seg.c', true), always(false)], value_type: 'bool')
    flag = config('the.flag', [
                    { 'criteria' => [
                      { 'propertyName' => '', 'operator' => 'IN_SEG',
                        'valueToMatch' => { 'type' => 'string', 'value' => 'seg.a' } },
                      { 'propertyName' => '', 'operator' => 'IN_SEG',
                        'valueToMatch' => { 'type' => 'string', 'value' => 'seg.b' } }
                    ], 'value' => { 'type' => 'string', 'value' => 'hit' } },
                    always('miss', type: 'string')
                  ])
    assert_equal 'hit', resolver_for(a, b, c, flag).get('the.flag', {}).unwrapped_value
  end

  # --- decryptWith ------------------------------------------------------

  def confidential(key, decrypt_with)
    config(key, [always(nil).merge('value' => { 'type' => 'string', 'value' => 'deadbeef--cafe--babe',
                                                'confidential' => true, 'decryptWith' => decrypt_with })])
  end

  def test_decrypt_with_self_cycle_raises_decryption_error
    key = confidential('key.a', 'key.a')
    secret = confidential('the.secret', 'key.a')
    err = assert_raises(Quonfig::Errors::DecryptionError) { resolver_for(key, secret).get('the.secret', {}) }
    assert_match(/cycle/, err.message)
  end

  def test_decrypt_with_two_hop_cycle_raises_decryption_error
    a = confidential('key.a', 'key.b')
    b = confidential('key.b', 'key.a')
    secret = confidential('the.secret', 'key.a')
    err = assert_raises(Quonfig::Errors::DecryptionError) { resolver_for(a, b, secret).get('the.secret', {}) }
    assert_match(/cycle/, err.message)
  end
end
