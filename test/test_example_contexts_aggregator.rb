# frozen_string_literal: true

require 'test_helper'
require 'timecop'

class TestExampleContextsAggregator < Minitest::Test
  def test_record
    aggregator = Quonfig::ExampleContextsAggregator.new(
      client: MockBaseClient.new, max_contexts: 2, sync_interval: EFFECTIVELY_NEVER
    )

    context = Quonfig::Context.new(user: { key: 'abc' }, device: { key: 'def', mobile: true })

    aggregator.record(context)
    assert_equal [context], aggregator.data

    aggregator.record(context)
    assert_equal [context], aggregator.data

    new_context = Quonfig::Context.new(user: { key: 'ghi', admin: true }, team: { key: '999' })
    aggregator.record(new_context)
    assert_equal [context, new_context], aggregator.data

    aggregator.record(Quonfig::Context.new(user: { key: 'new' }))
    assert_equal [context, new_context], aggregator.data
  end

  def test_prepare_data
    aggregator = Quonfig::ExampleContextsAggregator.new(
      client: MockBaseClient.new, max_contexts: 10, sync_interval: EFFECTIVELY_NEVER
    )

    context = Quonfig::Context.new(user: { key: 'abc' }, device: { key: 'def', mobile: true })
    aggregator.record(context)

    assert_equal [context], aggregator.prepare_data
    assert aggregator.data.empty?
  end

  def test_record_with_expiry
    aggregator = Quonfig::ExampleContextsAggregator.new(
      client: MockBaseClient.new, max_contexts: 10, sync_interval: EFFECTIVELY_NEVER
    )

    context = Quonfig::Context.new(user: { key: 'abc' }, device: { key: 'def', mobile: true })
    aggregator.record(context)
    assert_equal [context], aggregator.data

    Timecop.travel(Time.now + (60 * 60) - 1) do
      aggregator.record(context)
      assert_equal [context], aggregator.data
    end

    Timecop.travel(Time.now + ((60 * 60) + 1)) do
      aggregator.record(context)
      assert_equal [context, context], aggregator.data
    end
  end

  def test_sync_posts_json_payload_to_consolidated_endpoint
    now = Time.now

    client = MockBaseClient.new

    aggregator = Quonfig::ExampleContextsAggregator.new(
      client: client, max_contexts: 10, sync_interval: EFFECTIVELY_NEVER
    )

    context_abc = Quonfig::Context.new(user: { key: 'abc' }, device: { key: 'def', mobile: true })
    aggregator.record(context_abc)
    aggregator.record(context_abc) # dup — rate-limited away

    context_ghi = Quonfig::Context.new(user: { key: 'ghi' }, device: { key: 'jkl', mobile: false })
    aggregator.record(context_ghi)

    context_kev = Quonfig::Context.new(user: { key: 'kev', name: 'kevin', age: 48.5 })
    aggregator.record(context_kev)

    assert_equal 3, aggregator.cache.data.size

    requests = wait_for_post_requests(client) do
      Timecop.freeze(now + (60 * 60) - 1) { aggregator.sync }
    end

    assert_equal 1, requests.size
    path, body = requests.first
    assert_equal '/api/v1/telemetry/', path
    assert_equal client.instance_hash, body[:instanceHash]
    assert_equal 1, body[:events].size

    examples_event = body[:events][0][:exampleContexts]
    refute_nil examples_event, 'expected top-level :exampleContexts event'
    examples = examples_event[:examples]
    assert_equal 3, examples.size

    by_user_key = examples.each_with_object({}) do |example, acc|
      user = example[:contextSet][:contexts].find { |c| c[:type] == 'user' }
      acc[user[:values]['key']] = example
    end

    assert_equal %w[abc ghi kev].sort, by_user_key.keys.sort

    abc = by_user_key['abc']
    assert_equal context_abc.seen_at * 1000, abc[:timestamp]
    abc_contexts = abc[:contextSet][:contexts]
    abc_user = abc_contexts.find { |c| c[:type] == 'user' }
    abc_device = abc_contexts.find { |c| c[:type] == 'device' }
    assert_equal({ 'key' => 'abc' }, abc_user[:values])
    assert_equal({ 'key' => 'def', 'mobile' => true }, abc_device[:values])

    kev = by_user_key['kev']
    kev_user = kev[:contextSet][:contexts].find { |c| c[:type] == 'user' }
    assert_equal({ 'key' => 'kev', 'name' => 'kevin', 'age' => 48.5 }, kev_user[:values])
  end
end
