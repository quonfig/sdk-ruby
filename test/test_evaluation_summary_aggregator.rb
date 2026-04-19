# frozen_string_literal: true

require 'test_helper'
require 'timecop'

class TestEvaluationSummaryAggregator < Minitest::Test
  EFFECTIVELY_NEVER = 99_999 # we sync manually

  EXAMPLE_VALUE_1 = PrefabProto::ConfigValue.new(bool: true)
  EXAMPLE_VALUE_2 = PrefabProto::ConfigValue.new(bool: false)

  EXAMPLE_COUNTER = {
    config_id: 1,
    selected_index: 2,
    config_row_index: 3,
    conditional_value_index: 4,
    weighted_value_index: 5,
    seleced_value: EXAMPLE_VALUE_1
  }.freeze

  def test_increments_counts
    aggregator = Quonfig::EvaluationSummaryAggregator.new(client: MockBaseClient.new, max_keys: 10,
                                                         sync_interval: EFFECTIVELY_NEVER)

    aggregator.record(config_key: 'foo', config_type: 'bar', counter: EXAMPLE_COUNTER)

    assert_equal 1, aggregator.data[%w[foo bar]][EXAMPLE_COUNTER]

    2.times { aggregator.record(config_key: 'foo', config_type: 'bar', counter: EXAMPLE_COUNTER) }
    assert_equal 3, aggregator.data[%w[foo bar]][EXAMPLE_COUNTER]

    another_counter = EXAMPLE_COUNTER.merge(selected_index: EXAMPLE_COUNTER[:selected_index] + 1)

    aggregator.record(config_key: 'foo', config_type: 'bar', counter: another_counter)
    assert_equal 3, aggregator.data[%w[foo bar]][EXAMPLE_COUNTER]
    assert_equal 1, aggregator.data[%w[foo bar]][another_counter]
  end

  def test_prepare_data
    aggregator = Quonfig::EvaluationSummaryAggregator.new(client: MockBaseClient.new, max_keys: 10,
                                                         sync_interval: EFFECTIVELY_NEVER)

    expected = {
      ['config-1', :CONFIG] => {
        { config_id: 1, selected_index: 2, config_row_index: 3, conditional_value_index: 4,
          weighted_value_index: 5, selected_value: EXAMPLE_VALUE_1 } => 3,
        { config_id: 1, selected_index: 3, config_row_index: 7, conditional_value_index: 8,
          weighted_value_index: 10, selected_value: EXAMPLE_VALUE_2 } => 1
      },
      ['config-2', :FEATURE_FLAG] => {
        { config_id: 2, selected_index: 3, config_row_index: 5, conditional_value_index: 7,
          weighted_value_index: 6, selected_value: EXAMPLE_VALUE_1 } => 9
      }
    }

    add_example_data(aggregator)
    assert_equal expected, aggregator.prepare_data
    assert aggregator.data.empty?
  end

  def test_sync
    Timecop.freeze('2023-08-09 15:18:12 -0400') do
      awhile_ago = Time.now - 60
      now = Time.now

      client = MockBaseClient.new

      aggregator = nil

      Timecop.freeze(awhile_ago) do
        # start the aggregator in the past
        aggregator = Quonfig::EvaluationSummaryAggregator.new(client: client, max_keys: 10,
                                                           sync_interval: EFFECTIVELY_NEVER)
      end

      add_example_data(aggregator)

      expected_post = PrefabProto::TelemetryEvents.new(
        instance_hash: client.instance_hash,
        events: [
          PrefabProto::TelemetryEvent.new(
            summaries: PrefabProto::ConfigEvaluationSummaries.new(
              start: awhile_ago.to_i * 1000,
              end: now.to_i * 1000,
              summaries: [
                PrefabProto::ConfigEvaluationSummary.new(
                  key: 'config-1',
                  type: :CONFIG,
                  counters: [
                    PrefabProto::ConfigEvaluationCounter.new(
                      config_id: 1,
                      selected_index: 2,
                      config_row_index: 3,
                      conditional_value_index: 4,
                      weighted_value_index: 5,
                      selected_value: EXAMPLE_VALUE_1,
                      count: 3
                    ),
                    PrefabProto::ConfigEvaluationCounter.new(
                      config_id: 1,
                      selected_index: 3,
                      config_row_index: 7,
                      conditional_value_index: 8,
                      weighted_value_index: 10,
                      selected_value: EXAMPLE_VALUE_2,
                      count: 1
                    )
                  ]
                ),
                PrefabProto::ConfigEvaluationSummary.new(
                  key: 'config-2',
                  type: :FEATURE_FLAG,
                  counters: [
                    PrefabProto::ConfigEvaluationCounter.new(
                      config_id: 2,
                      selected_index: 3,
                      config_row_index: 5,
                      conditional_value_index: 7,
                      weighted_value_index: 6,
                      selected_value: EXAMPLE_VALUE_1,
                      count: 9
                    )
                  ]
                )
              ]
            )
          )
        ]
      )

      requests = wait_for_post_requests(client) do
        Timecop.freeze(now) do
          aggregator.sync
        end
      end

      assert_equal [[
        '/api/v1/telemetry',
        expected_post
      ]], requests
    end
  end

  private

  def add_example_data(aggregator)
    data = {
      ['config-1', :CONFIG] => {
        { config_id: 1, selected_index: 2, config_row_index: 3, conditional_value_index: 4,
          weighted_value_index: 5, selected_value: EXAMPLE_VALUE_1 } => 3,
        { config_id: 1, selected_index: 3, config_row_index: 7, conditional_value_index: 8,
          weighted_value_index: 10, selected_value: EXAMPLE_VALUE_2 } => 1
      },
      ['config-2', :FEATURE_FLAG] => {
        { config_id: 2, selected_index: 3, config_row_index: 5, conditional_value_index: 7,
          weighted_value_index: 6, selected_value: EXAMPLE_VALUE_1 } => 9
      }
    }

    aggregator.instance_variable_set('@data', data)
  end
end
