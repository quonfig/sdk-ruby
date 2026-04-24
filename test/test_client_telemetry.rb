# frozen_string_literal: true

require 'test_helper'

# Verifies that Quonfig::Client#get feeds every evaluation into the
# telemetry reporter's evaluation_summaries aggregator.
class TestClientTelemetry < Minitest::Test
  CONFIG_KEY = 'my.flag'

  class FakeHttpConnection
    FakeResponse = Struct.new(:status)
    attr_reader :posts
    def initialize; @posts = []; end
    def post(path, body); @posts << [path, body]; FakeResponse.new(200); end
  end

  # Plain ConfigResponse-shaped hash (matches Datadir.to_config_response).
  def make_config(key:, value:, type: 'string', criteria: nil)
    {
      'id' => 'cid-abc',
      'key' => key,
      'type' => 'config',
      'valueType' => type,
      'sendToClientSdk' => false,
      'default' => {
        'rules' => [
          {
            'criteria' => criteria || [{ 'operator' => 'ALWAYS_TRUE' }],
            'value' => { 'type' => type, 'value' => value }
          }
        ]
      },
      'environment' => nil
    }
  end

  def make_client_with_telemetry(store)
    client = Quonfig::Client.new(Quonfig::Options.new, store: store)

    # The store-injection path skips initialize_telemetry by design (it's
    # for test/bootstrap mode), so we attach the reporter + aggregators
    # here explicitly to exercise the record path.
    summaries_agg = Quonfig::Telemetry::EvaluationSummariesAggregator.new(max_keys: 100)
    shape_agg = Quonfig::Telemetry::ContextShapeAggregator.new(max_shapes: 100)
    example_agg = Quonfig::Telemetry::ExampleContextsAggregator.new(max_contexts: 100)

    options = Quonfig::Options.new(
      sdk_key: 'qf_sk_dev_abc_deadbeef',
      environment: 'development',
      api_urls: ['https://primary.example.com'],
      enable_sse: false,
      enable_polling: false,
      on_init_failure: Quonfig::Options::ON_INITIALIZATION_FAILURE::RETURN
    ).tap { |o| o.instance_variable_set(:@telemetry_destination, 'https://t.example.com') }

    fake_conn = FakeHttpConnection.new
    reporter = Quonfig::Telemetry::TelemetryReporter.new(
      options: options,
      instance_hash: client.instance_hash,
      context_shape_aggregator: shape_agg,
      example_contexts_aggregator: example_agg,
      evaluation_summaries_aggregator: summaries_agg,
      http_connection: fake_conn
    )
    client.instance_variable_set(:@telemetry_reporter, reporter)

    [client, reporter, summaries_agg, fake_conn]
  end

  def test_get_pushes_evaluation_into_summaries_aggregator
    store = Quonfig::ConfigStore.new
    store.set(CONFIG_KEY, make_config(key: CONFIG_KEY, value: 'hello'))

    client, _reporter, summaries_agg, _conn = make_client_with_telemetry(store)
    client.get(CONFIG_KEY, Quonfig::NO_DEFAULT_PROVIDED, 'user' => { 'key' => 'u1' })

    event = summaries_agg.drain_event
    refute_nil event, 'expected an evaluation_summaries event after Client#get'

    summary = event['summaries']['summaries'][0]
    assert_equal CONFIG_KEY, summary['key']
    assert_equal 'config',   summary['type']

    counter = summary['counters'][0]
    assert_equal 'cid-abc',                 counter['configId']
    assert_equal 0,                         counter['conditionalValueIndex']
    assert_equal 1,                         counter['count']
    assert_equal({ 'string' => 'hello' },   counter['selectedValue'])
    # ALWAYS_TRUE on the only rule → STATIC (1)
    assert_equal 1, counter['reason']
  end

  def test_get_with_targeting_rule_reports_targeting_match
    store = Quonfig::ConfigStore.new
    store.set(CONFIG_KEY, make_config(
      key: CONFIG_KEY,
      value: 'targeted',
      criteria: [{
        'operator' => 'PROP_IS_ONE_OF',
        'propertyName' => 'user.tier',
        'valueToMatch' => { 'type' => 'string_list', 'value' => ['pro'] }
      }]
    ))

    client, _reporter, summaries_agg, _conn = make_client_with_telemetry(store)
    client.get(CONFIG_KEY, 'fallback', 'user' => { 'key' => 'u1', 'tier' => 'pro' })

    counter = summaries_agg.drain_event['summaries']['summaries'][0]['counters'][0]
    # Config has a non-ALWAYS_TRUE rule → TARGETING_MATCH (2)
    assert_equal 2, counter['reason']
  end

  def test_repeated_get_increments_count_not_new_counters
    store = Quonfig::ConfigStore.new
    store.set(CONFIG_KEY, make_config(key: CONFIG_KEY, value: 'hello'))

    client, _reporter, summaries_agg, _conn = make_client_with_telemetry(store)
    3.times { client.get(CONFIG_KEY, Quonfig::NO_DEFAULT_PROVIDED, 'user' => { 'key' => 'u1' }) }

    counters = summaries_agg.drain_event['summaries']['summaries'][0]['counters']
    assert_equal 1, counters.size, 'same evaluation should dedupe into one counter'
    assert_equal 3, counters[0]['count']
  end

  def test_missing_key_does_not_record_evaluation
    store = Quonfig::ConfigStore.new
    client, _reporter, summaries_agg, _conn = make_client_with_telemetry(store)

    client.get('does.not.exist', 'fallback')
    assert_nil summaries_agg.drain_event
  end
end
