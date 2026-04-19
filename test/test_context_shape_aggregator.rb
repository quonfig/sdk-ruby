# frozen_string_literal: true

require 'test_helper'
require 'timecop'

class TestContextShapeAggregator < Minitest::Test
  DOB = Date.new

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
                                      'dob' => DOB
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

    # we've reached the limit so no more
    aggregator.push(CONTEXT_3)
    assert_equal 9, aggregator.data.size

    assert_equal [['user', 'name', 2], ['user', 'email', 2], ['user', 'age', 4], ['subscription', 'plan', 2], ['subscription', 'free', 5], ['user', 'dob', 2], ['device', 'name', 2], ['device', 'os', 2], ['device', 'version', 1]],
                 aggregator.data.to_a
  end

  def test_prepare_data
    aggregator = new_aggregator

    aggregator.push(CONTEXT_1)
    aggregator.push(CONTEXT_2)
    aggregator.push(CONTEXT_3)

    data = aggregator.prepare_data

    assert_equal %w[user subscription device], data.keys

    assert_equal data['user'], {
      'name' => 2,
      'email' => 2,
      'dob' => 2,
      'age' => 4
    }

    assert_equal data['subscription'], {
      'plan' => 2,
      'trial' => 5,
      'free' => 5
    }

    assert_equal data['device'], {
      'name' => 2,
      'os' => 2,
      'version' => 1
    }

    assert_equal [], aggregator.data.to_a
  end

  def test_sync
    client = new_client

    client.get 'some.key', 'default', CONTEXT_1
    client.get 'some.key', 'default', CONTEXT_2
    client.get 'some.key', 'default', CONTEXT_3

    requests = wait_for_post_requests(client) do
      client.context_shape_aggregator.send(:sync)
    end

    assert_equal [
      [
        '/api/v1/telemetry',
        PrefabProto::TelemetryEvents.new(
          instance_hash: client.instance_hash,
          events: [
            PrefabProto::TelemetryEvent.new(context_shapes:

            PrefabProto::ContextShapes.new(shapes: [
                                             PrefabProto::ContextShape.new(
                                               name: 'user', field_types: {
                                                 'age' => 4, 'dob' => 2, 'email' => 2, 'name' => 2
                                               }
                                             ),
                                             PrefabProto::ContextShape.new(
                                               name: 'subscription', field_types: {
                                                 'plan' => 2, 'free' => 5, 'trial' => 5
                                               }
                                             ),
                                             PrefabProto::ContextShape.new(
                                               name: 'device', field_types: {
                                                 'version' => 1, 'os' => 2, 'name' => 2
                                               }
                                             )
                                           ]))
          ]
        )
      ]
    ], requests

    assert_logged [
      'No success loading checkpoints',
      "Couldn't Initialize In 0. Key some.key. Returning what we have"
    ]
  end

  private

  def new_client(overrides = {})
    super(**{
      prefab_datasources: Quonfig::Options::DATASOURCES::ALL,
      initialization_timeout_sec: 0,
      on_init_failure: Quonfig::Options::ON_INITIALIZATION_FAILURE::RETURN,
      sdk_key: '123-development-yourapikey-SDK',
      context_upload_mode: :shape_only
    }.merge(overrides))
  end

  def new_aggregator(max_shapes: 1000)
    Quonfig::ContextShapeAggregator.new(client: new_client, sync_interval: 1000, max_shapes: max_shapes)
  end
end
