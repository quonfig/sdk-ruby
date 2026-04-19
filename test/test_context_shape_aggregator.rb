# frozen_string_literal: true

require 'test_helper'
require 'timecop'

class TestContextShapeAggregator < Minitest::Test
  CONTEXT_1 = Quonfig::Context.new({
                                     'user' => {
                                       'name' => 'user-name',
                                       'email' => 'user.email',
                                       'age' => 42.5
                                     },
                                     'subscription' => {
                                       'plan' => 'advanced',
                                       'free' => false
                                     }
                                   }).freeze

  CONTEXT_2 = Quonfig::Context.new({
                                     'user' => {
                                       'name' => 'other-user-name',
                                       'dob' => Date.new
                                     },
                                     'device' => {
                                       'name' => 'device-name',
                                       'os' => 'os-name',
                                       'version' => 3
                                     }
                                   }).freeze

  CONTEXT_3 = Quonfig::Context.new({
                                     'subscription' => {
                                       'plan' => 'pro',
                                       'trial' => true
                                     }
                                   }).freeze

  def test_push
    aggregator = new_aggregator(max_shapes: 9)

    aggregator.push(CONTEXT_1)
    aggregator.push(CONTEXT_2)
    assert_equal 9, aggregator.data.size

    # limit reached, context 3 is dropped
    aggregator.push(CONTEXT_3)
    assert_equal 9, aggregator.data.size
  end

  def test_prepare_data
    aggregator = new_aggregator

    aggregator.push(CONTEXT_1)
    aggregator.push(CONTEXT_2)
    aggregator.push(CONTEXT_3)

    data = aggregator.prepare_data

    assert_equal %w[user subscription device], data.keys

    assert_equal({ 'name' => 2, 'email' => 2, 'dob' => 2, 'age' => 4 }, data['user'])
    assert_equal({ 'plan' => 2, 'trial' => 5, 'free' => 5 }, data['subscription'])
    assert_equal({ 'name' => 2, 'os' => 2, 'version' => 1 }, data['device'])

    assert_equal [], aggregator.data.to_a
  end

  def test_sync_posts_json_payload_to_consolidated_endpoint
    client = MockBaseClient.new
    aggregator = Quonfig::ContextShapeAggregator.new(
      client: client, max_shapes: 1000, sync_interval: EFFECTIVELY_NEVER
    )

    aggregator.push(CONTEXT_1)
    aggregator.push(CONTEXT_2)
    aggregator.push(CONTEXT_3)

    requests = wait_for_post_requests(client) { aggregator.sync }

    assert_equal 1, requests.size
    path, body = requests.first
    assert_equal '/api/v1/telemetry/', path
    assert_equal client.instance_hash, body[:instanceHash]
    assert_equal 1, body[:events].size

    shapes_event = body[:events][0][:contextShapes]
    refute_nil shapes_event, 'expected top-level :contextShapes event'
    shapes = shapes_event[:shapes]

    by_name = shapes.each_with_object({}) { |s, acc| acc[s[:name]] = s[:fieldTypes] }
    assert_equal(%w[user subscription device].sort, by_name.keys.sort)
    assert_equal({ 'name' => 2, 'email' => 2, 'dob' => 2, 'age' => 4 }, by_name['user'])
    assert_equal({ 'plan' => 2, 'trial' => 5, 'free' => 5 }, by_name['subscription'])
    assert_equal({ 'name' => 2, 'os' => 2, 'version' => 1 }, by_name['device'])
  end

  private

  def new_aggregator(max_shapes: 1000)
    Quonfig::ContextShapeAggregator.new(
      client: MockBaseClient.new, sync_interval: EFFECTIVELY_NEVER, max_shapes: max_shapes
    )
  end
end
