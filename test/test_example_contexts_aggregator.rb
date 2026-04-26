# frozen_string_literal: true

require 'test_helper'
require 'timecop'

class TestExampleContextsAggregator < Minitest::Test
  def test_record_dedupes_within_window
    aggregator = Quonfig::Telemetry::ExampleContextsAggregator.new(max_contexts: 2)

    context = Quonfig::Context.new(
      'user' => { 'key' => 'abc' },
      'device' => { 'key' => 'def', 'mobile' => true }
    )

    aggregator.record(context)
    assert_equal 1, aggregator.data.size

    # Same grouped key → skipped.
    aggregator.record(context)
    assert_equal 1, aggregator.data.size

    new_context = Quonfig::Context.new(
      'user' => { 'key' => 'ghi', 'admin' => true },
      'team' => { 'key' => '999' }
    )

    aggregator.record(new_context)
    assert_equal 2, aggregator.data.size

    # At max_contexts — next record is dropped.
    aggregator.record(Quonfig::Context.new('user' => { 'key' => 'new' }))
    assert_equal 2, aggregator.data.size
  end

  def test_record_drops_contexts_without_a_key_property
    aggregator = Quonfig::Telemetry::ExampleContextsAggregator.new(max_contexts: 10)

    # Anonymous contexts (no `key` / `trackingId`) produce an empty
    # grouped_key under the sdk-node-aligned shape. The aggregator drops
    # them so we don't ship rows the backend can't dedupe.
    aggregator.record(Quonfig::Context.new('user' => { 'name' => 'no-key' }))
    aggregator.record(Quonfig::Context.new('user' => { 'name' => 'still-no-key' }))
    assert_equal 0, aggregator.data.size
  end

  def test_record_with_expiry_allows_re_recording_after_window
    aggregator = Quonfig::Telemetry::ExampleContextsAggregator.new(max_contexts: 10)

    context = Quonfig::Context.new(
      'user' => { 'key' => 'abc' },
      'device' => { 'key' => 'def', 'mobile' => true }
    )

    aggregator.record(context)
    assert_equal 1, aggregator.data.size

    Timecop.travel(Time.now + (60 * 60) - 1) do
      aggregator.record(context)
      assert_equal 1, aggregator.data.size
    end

    Timecop.travel(Time.now + (60 * 60) + 1) do
      aggregator.record(context)
      assert_equal 2, aggregator.data.size
    end
  end

  def test_drain_event_emits_api_telemetry_wire_shape
    aggregator = Quonfig::Telemetry::ExampleContextsAggregator.new(max_contexts: 10)

    aggregator.record(
      Quonfig::Context.new(
        'user' => { 'key' => 'abc' },
        'device' => { 'key' => 'def', 'mobile' => true }
      )
    )
    aggregator.record(
      Quonfig::Context.new('user' => { 'key' => 'kev', 'name' => 'kevin', 'age' => 48.5 })
    )

    event = aggregator.drain_event

    refute_nil event
    assert event.key?('exampleContexts')
    examples = event['exampleContexts']['examples']
    assert_equal 2, examples.size

    first = examples[0]
    assert_kind_of Integer, first['timestamp']
    assert first['timestamp'] > 0

    contexts_list = first['contextSet']['contexts']
    user_ctx = contexts_list.find { |c| c['type'] == 'user' }
    device_ctx = contexts_list.find { |c| c['type'] == 'device' }

    refute_nil user_ctx
    refute_nil device_ctx
    assert_equal 'abc', user_ctx['values']['key']
    assert_equal true, device_ctx['values']['mobile']

    second = examples[1]
    user_ctx = second['contextSet']['contexts'].find { |c| c['type'] == 'user' }
    assert_equal 'kev', user_ctx['values']['key']
    assert_equal 'kevin', user_ctx['values']['name']
    assert_in_delta 48.5, user_ctx['values']['age']
  end

  def test_drain_event_nil_when_empty
    aggregator = Quonfig::Telemetry::ExampleContextsAggregator.new(max_contexts: 10)
    assert_nil aggregator.drain_event
  end

  def test_drain_clears_data
    aggregator = Quonfig::Telemetry::ExampleContextsAggregator.new(max_contexts: 10)
    aggregator.record(Quonfig::Context.new('user' => { 'key' => 'abc' }))
    aggregator.drain_event
    assert_equal 0, aggregator.data.size
  end
end
