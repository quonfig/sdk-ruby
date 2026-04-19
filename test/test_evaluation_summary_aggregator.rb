# frozen_string_literal: true

require 'test_helper'
require 'timecop'

class TestEvaluationSummaryAggregator < Minitest::Test
  EXAMPLE_COUNTER = {
    config_id: 'cfg-1',
    selected_index: 2,
    config_row_index: 3,
    conditional_value_index: 4,
    weighted_value_index: 5,
    selected_value: { bool: true }
  }.freeze

  def test_increments_counts
    aggregator = Quonfig::EvaluationSummaryAggregator.new(
      client: MockBaseClient.new, max_keys: 10, sync_interval: EFFECTIVELY_NEVER
    )

    aggregator.record(config_key: 'foo', config_type: 'bar', counter: EXAMPLE_COUNTER)
    assert_equal 1, aggregator.data[%w[foo bar]][EXAMPLE_COUNTER]

    2.times { aggregator.record(config_key: 'foo', config_type: 'bar', counter: EXAMPLE_COUNTER) }
    assert_equal 3, aggregator.data[%w[foo bar]][EXAMPLE_COUNTER]

    another_counter = EXAMPLE_COUNTER.merge(selected_index: EXAMPLE_COUNTER[:selected_index] + 1)
    aggregator.record(config_key: 'foo', config_type: 'bar', counter: another_counter)
    assert_equal 3, aggregator.data[%w[foo bar]][EXAMPLE_COUNTER]
    assert_equal 1, aggregator.data[%w[foo bar]][another_counter]
  end

  def test_prepare_data_clears_data
    aggregator = Quonfig::EvaluationSummaryAggregator.new(
      client: MockBaseClient.new, max_keys: 10, sync_interval: EFFECTIVELY_NEVER
    )

    aggregator.record(config_key: 'foo', config_type: 'bar', counter: EXAMPLE_COUNTER)
    refute aggregator.data.empty?

    aggregator.prepare_data
    assert aggregator.data.empty?
  end

  def test_sync_posts_json_payload_to_consolidated_endpoint
    Timecop.freeze(Time.utc(2026, 4, 19, 15, 0, 0)) do
      awhile_ago = Time.now - 60
      now = Time.now

      client = MockBaseClient.new

      aggregator = Timecop.freeze(awhile_ago) do
        Quonfig::EvaluationSummaryAggregator.new(
          client: client, max_keys: 10, sync_interval: EFFECTIVELY_NEVER
        )
      end

      aggregator.instance_variable_set('@data', {
        ['config-1', 'FEATURE_FLAG'] => {
          { config_id: 'c1', conditional_value_index: 0, config_row_index: 0,
            selected_value: { bool: true }, weighted_value_index: nil,
            selected_index: nil, reason: 1 } => 3
        },
        ['config-2', 'CONFIG'] => {
          { config_id: 'c2', conditional_value_index: 1, config_row_index: 0,
            selected_value: { string: 'xyz' }, weighted_value_index: 0,
            selected_index: nil, reason: 3 } => 9
        }
      })

      requests = wait_for_post_requests(client) do
        Timecop.freeze(now) { aggregator.sync }
      end

      assert_equal 1, requests.size
      path, body = requests.first
      assert_equal '/api/v1/telemetry/', path
      assert_equal client.instance_hash, body[:instanceHash]
      assert_equal 1, body[:events].size

      summaries_event = body[:events][0][:summaries]
      refute_nil summaries_event, 'expected top-level :summaries event'
      assert_equal awhile_ago.to_i * 1000, summaries_event[:start]
      assert_equal now.to_i * 1000, summaries_event[:end]

      by_key = summaries_event[:summaries].each_with_object({}) { |s, acc| acc[s[:key]] = s }
      assert_equal %w[config-1 config-2].sort, by_key.keys.sort

      c1 = by_key['config-1']
      assert_equal 'FEATURE_FLAG', c1[:type]
      assert_equal 1, c1[:counters].size
      cnt1 = c1[:counters].first
      assert_equal 'c1', cnt1[:configId]
      assert_equal 0, cnt1[:conditionalValueIndex]
      assert_equal 0, cnt1[:configRowIndex]
      assert_equal({ bool: true }, cnt1[:selectedValue])
      assert_equal 3, cnt1[:count]
      assert_equal 1, cnt1[:reason]
      refute cnt1.key?(:weightedValueIndex),
             "weightedValueIndex=nil should be omitted, got: #{cnt1[:weightedValueIndex].inspect}"

      c2 = by_key['config-2']
      assert_equal 'CONFIG', c2[:type]
      cnt2 = c2[:counters].first
      assert_equal 'c2', cnt2[:configId]
      assert_equal({ string: 'xyz' }, cnt2[:selectedValue])
      assert_equal 9, cnt2[:count]
      assert_equal 3, cnt2[:reason]
      assert_equal 0, cnt2[:weightedValueIndex]
    end
  end
end
