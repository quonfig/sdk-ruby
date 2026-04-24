# frozen_string_literal: true

require 'test_helper'

class TestContextShapeAggregator < Minitest::Test
  CONTEXT_1 = Quonfig::Context.new(
    'user' => {
      'name' => 'user-name',
      'email' => 'user.email',
      'age' => 42.5
    },
    'subscription' => {
      'plan' => 'advanced',
      'free' => false
    }
  ).freeze

  CONTEXT_2 = Quonfig::Context.new(
    'user' => {
      'name' => 'other-user-name',
      'dob' => '2020-01-01'
    },
    'device' => {
      'name' => 'device-name',
      'os' => 'os-name',
      'version' => 3
    }
  ).freeze

  CONTEXT_3 = Quonfig::Context.new(
    'subscription' => {
      'plan' => 'pro',
      'trial' => true
    }
  ).freeze

  def test_push_respects_max_shapes
    aggregator = Quonfig::Telemetry::ContextShapeAggregator.new(max_shapes: 9)

    aggregator.push(CONTEXT_1)
    aggregator.push(CONTEXT_2)
    assert_equal 9, aggregator.data.size

    # At the limit — further shapes get dropped.
    aggregator.push(CONTEXT_3)
    assert_equal 9, aggregator.data.size

    tuples = aggregator.data.to_a
    assert_includes tuples, ['user', 'name', 2]
    assert_includes tuples, ['user', 'email', 2]
    assert_includes tuples, ['user', 'age', 4]
    assert_includes tuples, ['subscription', 'plan', 2]
    assert_includes tuples, ['subscription', 'free', 5]
    assert_includes tuples, ['device', 'name', 2]
    assert_includes tuples, ['device', 'os', 2]
    assert_includes tuples, ['device', 'version', 1]
  end

  def test_prepare_data_folds_tuples_and_clears
    aggregator = Quonfig::Telemetry::ContextShapeAggregator.new(max_shapes: 1000)

    aggregator.push(CONTEXT_1)
    aggregator.push(CONTEXT_2)
    aggregator.push(CONTEXT_3)

    data = aggregator.prepare_data

    assert_equal %w[user subscription device].sort, data.keys.sort

    assert_equal(
      { 'name' => 2, 'email' => 2, 'dob' => 2, 'age' => 4 },
      data['user']
    )

    assert_equal(
      { 'plan' => 2, 'trial' => 5, 'free' => 5 },
      data['subscription']
    )

    assert_equal(
      { 'name' => 2, 'os' => 2, 'version' => 1 },
      data['device']
    )

    assert_equal [], aggregator.data.to_a
  end

  def test_drain_event_emits_api_telemetry_wire_shape
    aggregator = Quonfig::Telemetry::ContextShapeAggregator.new(max_shapes: 1000)
    aggregator.push(Quonfig::Context.new('user' => { 'key' => 'abc', 'age' => 42 }))

    event = aggregator.drain_event

    refute_nil event
    assert event.key?('contextShapes')
    shapes = event['contextShapes']['shapes']
    assert_equal 1, shapes.size
    assert_equal 'user', shapes[0]['name']
    assert_equal({ 'key' => 2, 'age' => 1 }, shapes[0]['fieldTypes'])
  end

  def test_drain_event_nil_when_empty
    aggregator = Quonfig::Telemetry::ContextShapeAggregator.new(max_shapes: 1000)
    assert_nil aggregator.drain_event
  end

  def test_push_dedupes_identical_shapes
    aggregator = Quonfig::Telemetry::ContextShapeAggregator.new(max_shapes: 1000)

    aggregator.push(Quonfig::Context.new('user' => { 'key' => 'a', 'age' => 1 }))
    aggregator.push(Quonfig::Context.new('user' => { 'key' => 'b', 'age' => 2 }))

    # Same (name, key, type) tuples should have been deduped by the Set.
    assert_equal 2, aggregator.data.size
  end

  def test_accepts_plain_hash_context
    aggregator = Quonfig::Telemetry::ContextShapeAggregator.new(max_shapes: 1000)

    aggregator.push('user' => { 'key' => 'abc', 'is_admin' => true })

    event = aggregator.drain_event
    refute_nil event
    assert_equal({ 'key' => 2, 'is_admin' => 5 }, event['contextShapes']['shapes'][0]['fieldTypes'])
  end
end
