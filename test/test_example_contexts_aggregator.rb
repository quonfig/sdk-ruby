# frozen_string_literal: true

require 'test_helper'
require 'timecop'

class TestExampleContextsAggregator < Minitest::Test
  def test_record
    aggregator = Quonfig::ExampleContextsAggregator.new(client: MockBaseClient.new, max_contexts: 2,
                                                       sync_interval: EFFECTIVELY_NEVER)

    context = Quonfig::Context.new(user: { key: 'abc' }, device: { key: 'def', mobile: true })

    aggregator.record(context)
    assert_equal [context], aggregator.data

    # This doesn't get updated because we already have a context for this user/device
    aggregator.record(context)
    assert_equal [context], aggregator.data

    new_context = Quonfig::Context.new(
      user: { key: 'ghi', admin: true },
      team: { key: '999' }
    )

    aggregator.record(new_context)
    assert_equal [context, new_context], aggregator.data

    # this doesn't get recorded because we're at max_contexts
    aggregator.record(Quonfig::Context.new(user: { key: 'new' }))
    assert_equal [context, new_context], aggregator.data
  end

  def test_prepare_data
    aggregator = Quonfig::ExampleContextsAggregator.new(client: MockBaseClient.new, max_contexts: 10,
                                                       sync_interval: EFFECTIVELY_NEVER)

    context = Quonfig::Context.new(
      user: { key: 'abc' },
      device: { key: 'def', mobile: true }
    )

    aggregator.record(context)

    assert_equal [context], aggregator.prepare_data
    assert aggregator.data.empty?
  end

  def test_record_with_expiry
    aggregator = Quonfig::ExampleContextsAggregator.new(client: MockBaseClient.new, max_contexts: 10,
                                                       sync_interval: EFFECTIVELY_NEVER)

    context = Quonfig::Context.new(
      user: { key: 'abc' },
      device: { key: 'def', mobile: true }
    )

    aggregator.record(context)

    assert_equal [context], aggregator.data

    Timecop.travel(Time.now + (60 * 60) - 1) do
      aggregator.record(context)

      # This doesn't get updated because we already have a context for this user/device in the timeframe
      assert_equal [context], aggregator.data
    end

    Timecop.travel(Time.now + ((60 * 60) + 1)) do
      # this is new because we've passed the expiry
      aggregator.record(context)

      assert_equal [context, context], aggregator.data
    end
  end

  def test_sync
    now = Time.now

    client = MockBaseClient.new

    aggregator = Quonfig::ExampleContextsAggregator.new(client: client, max_contexts: 10,
                                                       sync_interval: EFFECTIVELY_NEVER)

    context = Quonfig::Context.new(
      user: { key: 'abc' },
      device: { key: 'def', mobile: true }
    )
    aggregator.record(context)

    # This is the same as above so we shouldn't get anything new
    aggregator.record(context)

    aggregator.record(
      Quonfig::Context.new(
        user: { key: 'ghi' },
        device: { key: 'jkl', mobile: false }
      )
    )

    aggregator.record(Quonfig::Context.new(user: { key: 'kev', name: 'kevin', age: 48.5 }))

    assert_equal 3, aggregator.cache.data.size

    expected_post = PrefabProto::TelemetryEvents.new(
      instance_hash: client.instance_hash,
      events: [
        PrefabProto::TelemetryEvent.new(
          example_contexts: PrefabProto::ExampleContexts.new(
            examples: [
              PrefabProto::ExampleContext.new(
                timestamp: now.utc.to_i * 1000,
                contextSet: PrefabProto::ContextSet.new(
                  contexts: [
                    PrefabProto::Context.new(
                      type: 'user',
                      values: {
                        'key' => PrefabProto::ConfigValue.new(string: 'abc')
                      }
                    ),
                    PrefabProto::Context.new(
                      type: 'device',
                      values: {
                        'key' => PrefabProto::ConfigValue.new(string: 'def'),
                        'mobile' => PrefabProto::ConfigValue.new(bool: true)
                      }
                    )
                  ]
                )
              ),

              PrefabProto::ExampleContext.new(
                timestamp: now.utc.to_i * 1000,
                contextSet: PrefabProto::ContextSet.new(
                  contexts: [
                    PrefabProto::Context.new(
                      type: 'user',
                      values: {
                        'key' => PrefabProto::ConfigValue.new(string: 'ghi')
                      }
                    ),
                    PrefabProto::Context.new(
                      type: 'device',
                      values: {
                        'key' => PrefabProto::ConfigValue.new(string: 'jkl'),
                        'mobile' => PrefabProto::ConfigValue.new(bool: false)
                      }
                    )
                  ]
                )
              ),

              PrefabProto::ExampleContext.new(
                timestamp: now.utc.to_i * 1000,
                contextSet: PrefabProto::ContextSet.new(
                  contexts: [
                    PrefabProto::Context.new(
                      type: 'user',
                      values: {
                        'key' => PrefabProto::ConfigValue.new(string: 'kev'),
                        'name' => PrefabProto::ConfigValue.new(string: 'kevin'),
                        'age' => PrefabProto::ConfigValue.new(double: 48.5)
                      }
                    )
                  ]
                )
              )
            ]
          )
        )
      ]
    )

    requests = wait_for_post_requests(client) do
      Timecop.freeze(now + (60 * 60) - 1) do
        aggregator.sync
      end
    end

    assert_equal [[
      '/api/v1/telemetry',
      expected_post
    ]], requests

    # this hasn't changed because not enough time has passed
    assert_equal 3, aggregator.cache.data.size

    # a sync past the expiry should clear the cache
    Timecop.freeze(now + (60 * 60) + 1) do
      # we need a new piece of data for the sync to happen
      aggregator.record(Quonfig::Context.new(user: { key: 'bozo', name: 'Bozo', age: 99 }))

      requests = wait_for_post_requests(client) do
        aggregator.sync
      end
    end

    expected_post = PrefabProto::TelemetryEvents.new(
      instance_hash: client.instance_hash,
      events: [
        PrefabProto::TelemetryEvent.new(
          example_contexts: PrefabProto::ExampleContexts.new(
            examples: [
              PrefabProto::ExampleContext.new(
                timestamp: (now.utc.to_i + (60 * 60) + 1) * 1000,
                contextSet: PrefabProto::ContextSet.new(
                  contexts: [
                    PrefabProto::Context.new(
                      type: 'user',
                      values: {
                        'key' => PrefabProto::ConfigValue.new(string: 'bozo'),
                        'name' => PrefabProto::ConfigValue.new(string: 'Bozo'),
                        'age' => PrefabProto::ConfigValue.new(int: 99)
                      }
                    )
                  ]
                )
              )
            ]
          )
        )
      ]
    )

    assert_equal [[
      '/api/v1/telemetry',
      expected_post
    ]], requests

    # The last sync should have cleared the cache of everything except the latest context
    assert_equal 1, aggregator.cache.data.size
    assert_equal ['user:bozo'], aggregator.cache.data.keys
  end
end
