# frozen_string_literal: true

require 'test_helper'

class TestEvaluationSummariesAggregator < Minitest::Test
  def make_aggregator(max_keys: 100)
    Quonfig::Telemetry::EvaluationSummariesAggregator.new(max_keys: max_keys)
  end

  def record_eval(agg, overrides = {})
    defaults = {
      config_id: 'c1',
      config_key: 'my-test-key',
      config_type: 'config',
      conditional_value_index: 0,
      weighted_value_index: nil,
      selected_value: 'hello',
      reason: 1
    }
    agg.record(**defaults.merge(overrides))
  end

  def test_record_dedupes_identical_evaluations_into_one_counter
    agg = make_aggregator

    record_eval(agg)
    record_eval(agg)
    record_eval(agg)

    event = agg.drain_event
    refute_nil event
    summaries = event['summaries']['summaries']
    assert_equal 1, summaries.size

    counters = summaries[0]['counters']
    assert_equal 1, counters.size
    assert_equal 3, counters[0]['count']
  end

  def test_record_creates_separate_counters_for_different_rule_indexes
    agg = make_aggregator

    record_eval(agg, conditional_value_index: 0)
    record_eval(agg, conditional_value_index: 1)
    record_eval(agg, conditional_value_index: 1)

    summaries = agg.drain_event['summaries']['summaries']
    assert_equal 1, summaries.size

    counters = summaries[0]['counters']
    assert_equal 2, counters.size

    by_idx = counters.each_with_object({}) { |c, h| h[c['conditionalValueIndex']] = c['count'] }
    assert_equal 1, by_idx[0]
    assert_equal 2, by_idx[1]
  end

  def test_record_groups_by_config_key_and_type
    agg = make_aggregator

    record_eval(agg, config_key: 'alpha', config_type: 'config')
    record_eval(agg, config_key: 'alpha', config_type: 'config')
    record_eval(agg, config_key: 'beta',  config_type: 'feature_flag')

    summaries = agg.drain_event['summaries']['summaries']
    assert_equal 2, summaries.size

    by_key = summaries.each_with_object({}) { |s, h| h[s['key']] = s }
    assert_equal 'config',        by_key['alpha']['type']
    assert_equal 'feature_flag',  by_key['beta']['type']
    assert_equal 2, by_key['alpha']['counters'][0]['count']
    assert_equal 1, by_key['beta']['counters'][0]['count']
  end

  def test_drain_event_nil_when_empty
    agg = make_aggregator
    assert_nil agg.drain_event
  end

  def test_drain_clears_state
    agg = make_aggregator
    record_eval(agg)

    refute_nil agg.drain_event
    assert_nil agg.drain_event, 'second drain with no new records should be nil'
  end

  def test_drain_event_wire_shape
    agg = make_aggregator

    record_eval(agg,
                config_id: 'cid-42',
                config_key: 'my-test-key',
                config_type: 'config',
                conditional_value_index: 1,
                weighted_value_index: nil,
                selected_value: 'my-test-value',
                reason: 2)

    event = agg.drain_event
    refute_nil event
    assert event.key?('summaries'), 'top-level event key is summaries'

    inner = event['summaries']
    assert_kind_of Integer, inner['start']
    assert_kind_of Integer, inner['end']
    assert inner['end'] >= inner['start']

    summary = inner['summaries'][0]
    assert_equal 'my-test-key', summary['key']
    assert_equal 'config',      summary['type']

    counter = summary['counters'][0]
    assert_equal 'cid-42',         counter['configId']
    assert_equal 1,                counter['conditionalValueIndex']
    assert_equal 0,                counter['configRowIndex']
    assert_equal 1,                counter['count']
    assert_equal 2,                counter['reason']
    assert_equal({ 'string' => 'my-test-value' }, counter['selectedValue'])
    refute counter.key?('weightedValueIndex'),
           'weightedValueIndex omitted when nil'
  end

  def test_selected_value_wrapper_keys_match_prefab_shape
    agg = make_aggregator

    record_eval(agg, selected_value: true,      conditional_value_index: 0)
    record_eval(agg, selected_value: 3,         conditional_value_index: 1)
    record_eval(agg, selected_value: 1.5,       conditional_value_index: 2)
    record_eval(agg, selected_value: 'hi',      conditional_value_index: 3)
    record_eval(agg, selected_value: %w[a b],   conditional_value_index: 4)

    counters = agg.drain_event['summaries']['summaries'][0]['counters']
    by_idx = counters.each_with_object({}) { |c, h| h[c['conditionalValueIndex']] = c['selectedValue'] }

    assert_equal({ 'bool'       => true },  by_idx[0])
    assert_equal({ 'int'        => 3 },     by_idx[1])
    assert_equal({ 'double'     => 1.5 },   by_idx[2])
    assert_equal({ 'string'     => 'hi' },  by_idx[3])
    assert_equal({ 'stringList' => %w[a b] }, by_idx[4])
  end

  def test_weighted_value_index_included_when_present
    agg = make_aggregator

    record_eval(agg, weighted_value_index: 2, reason: 3)

    counter = agg.drain_event['summaries']['summaries'][0]['counters'][0]
    assert_equal 2, counter['weightedValueIndex']
    assert_equal 3, counter['reason']
  end

  def test_log_level_evaluations_are_excluded
    agg = make_aggregator

    record_eval(agg, config_type: 'log_level')

    assert_nil agg.drain_event
  end

  def test_record_caps_at_max_keys
    agg = make_aggregator(max_keys: 2)

    record_eval(agg, config_key: 'a')
    record_eval(agg, config_key: 'b')
    record_eval(agg, config_key: 'c') # dropped — at cap

    summaries = agg.drain_event['summaries']['summaries']
    keys = summaries.map { |s| s['key'] }.sort
    assert_equal %w[a b], keys
  end

  def test_noop_when_max_keys_zero
    agg = make_aggregator(max_keys: 0)

    record_eval(agg)

    assert_nil agg.drain_event
  end
end
