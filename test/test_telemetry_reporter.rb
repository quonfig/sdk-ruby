# frozen_string_literal: true

require 'test_helper'

class TestTelemetryReporter < Minitest::Test
  # Minimal stand-in for Quonfig::HttpConnection that records POSTs.
  class FakeHttpConnection
    FakeResponse = Struct.new(:status)

    attr_reader :posts

    def initialize
      @posts = []
    end

    def post(path, body)
      @posts << [path, body]
      FakeResponse.new(200)
    end
  end

  def make_options(telemetry_destination: 'https://telemetry.example.com',
                   sdk_key: 'qf_sk_development_abc_deadbeef')
    # Build minimal Options bypassing env-var lookups via explicit overrides.
    Quonfig::Options.new(
      sdk_key: sdk_key,
      environment: 'development',
      api_urls: ['https://primary.example.com'],
      enable_sse: false,
      enable_polling: false,
      on_init_failure: Quonfig::Options::ON_INITIALIZATION_FAILURE::RETURN,
      context_upload_mode: :periodic_example
    ).tap do |opts|
      opts.instance_variable_set(:@telemetry_destination, telemetry_destination)
    end
  end

  def test_sync_posts_combined_events_in_api_telemetry_wire_shape
    options = make_options
    fake = FakeHttpConnection.new

    shape_agg = Quonfig::Telemetry::ContextShapeAggregator.new(max_shapes: 100)
    example_agg = Quonfig::Telemetry::ExampleContextsAggregator.new(max_contexts: 100)

    reporter = Quonfig::Telemetry::TelemetryReporter.new(
      options: options,
      instance_hash: 'fake-instance-hash',
      context_shape_aggregator: shape_agg,
      example_contexts_aggregator: example_agg,
      http_connection: fake
    )

    ctx = Quonfig::Context.new('user' => { 'key' => 'abc', 'age' => 33 })
    shape_agg.push(ctx)
    example_agg.record(ctx)

    reporter.sync

    assert_equal 1, fake.posts.size
    path, body = fake.posts.first
    assert_equal '/api/v1/telemetry/', path

    # Wire shape: TelemetryEventsSchema
    assert_equal 'fake-instance-hash', body['instanceHash']
    assert_kind_of Array, body['events']
    assert_equal 2, body['events'].size

    shape_event = body['events'].find { |e| e.key?('contextShapes') }
    example_event = body['events'].find { |e| e.key?('exampleContexts') }

    refute_nil shape_event
    refute_nil example_event

    # ContextShapesSchema: { shapes: [{ name, fieldTypes }] }
    shapes = shape_event['contextShapes']['shapes']
    assert_equal 1, shapes.size
    assert_equal 'user', shapes[0]['name']
    assert_equal({ 'key' => 2, 'age' => 1 }, shapes[0]['fieldTypes'])

    # ExampleContextsSchema: { examples: [{ timestamp, contextSet: { contexts: [...] } }] }
    examples = example_event['exampleContexts']['examples']
    assert_equal 1, examples.size
    assert_kind_of Integer, examples[0]['timestamp']
    contexts_list = examples[0]['contextSet']['contexts']
    assert_equal 'user', contexts_list[0]['type']
    assert_equal 'abc', contexts_list[0]['values']['key']
    assert_equal 33, contexts_list[0]['values']['age']
  end

  def test_sync_noop_when_aggregators_empty
    fake = FakeHttpConnection.new
    reporter = Quonfig::Telemetry::TelemetryReporter.new(
      options: make_options,
      instance_hash: 'h',
      context_shape_aggregator: Quonfig::Telemetry::ContextShapeAggregator.new(max_shapes: 10),
      example_contexts_aggregator: Quonfig::Telemetry::ExampleContextsAggregator.new(max_contexts: 10),
      http_connection: fake
    )

    reporter.sync
    assert_equal 0, fake.posts.size
  end

  def test_enabled_requires_sdk_key_and_destination
    options = make_options(sdk_key: '')
    reporter = Quonfig::Telemetry::TelemetryReporter.new(
      options: options,
      instance_hash: 'h',
      context_shape_aggregator: Quonfig::Telemetry::ContextShapeAggregator.new(max_shapes: 10)
    )
    refute reporter.enabled?
  end

  def test_record_feeds_both_aggregators
    fake = FakeHttpConnection.new
    shape_agg = Quonfig::Telemetry::ContextShapeAggregator.new(max_shapes: 100)
    example_agg = Quonfig::Telemetry::ExampleContextsAggregator.new(max_contexts: 100)

    reporter = Quonfig::Telemetry::TelemetryReporter.new(
      options: make_options,
      instance_hash: 'h',
      context_shape_aggregator: shape_agg,
      example_contexts_aggregator: example_agg,
      http_connection: fake
    )

    reporter.record(Quonfig::Context.new('user' => { 'key' => 'zzz' }))

    refute_nil shape_agg.drain_event
    refute_nil example_agg.drain_event
  end

  def test_sync_posts_evaluation_summaries_event
    fake = FakeHttpConnection.new
    summaries_agg = Quonfig::Telemetry::EvaluationSummariesAggregator.new(max_keys: 100)

    reporter = Quonfig::Telemetry::TelemetryReporter.new(
      options: make_options,
      instance_hash: 'h',
      evaluation_summaries_aggregator: summaries_agg,
      http_connection: fake
    )

    summaries_agg.record(
      config_id: 'cid',
      config_key: 'my-key',
      config_type: 'config',
      conditional_value_index: 0,
      selected_value: 'v',
      reason: 1
    )

    reporter.sync

    assert_equal 1, fake.posts.size
    _path, body = fake.posts.first

    summaries_event = body['events'].find { |e| e.key?('summaries') }
    refute_nil summaries_event, 'expected a summaries event in the payload'

    inner = summaries_event['summaries']
    assert_kind_of Array, inner['summaries']
    counter = inner['summaries'][0]['counters'][0]
    assert_equal 1, counter['count']
    assert_equal 1, counter['reason']
  end

  def test_at_exit_final_drain_posts_pending_batch
    fake = FakeHttpConnection.new
    shape_agg = Quonfig::Telemetry::ContextShapeAggregator.new(max_shapes: 100)

    reporter = Quonfig::Telemetry::TelemetryReporter.new(
      options: make_options,
      instance_hash: 'h',
      context_shape_aggregator: shape_agg,
      http_connection: fake
    )

    # Simulate evaluations accumulating between sync cycles.
    shape_agg.push(Quonfig::Context.new('user' => { 'key' => 'x' }))

    # Simulate a Rails SIGTERM: process exits without Client#stop being
    # called. The reporter's at_exit handler must flush the pending batch.
    reporter.send(:final_drain_on_exit)

    assert_equal 1, fake.posts.size
    _path, body = fake.posts.first
    refute_nil body['events'].find { |e| e.key?('contextShapes') }
  end

  def test_at_exit_handler_registered_on_start
    # Guards against regressing the Kernel.at_exit hookup that catches
    # Rails / Passenger worker SIGTERMs where Client#stop isn't called.
    fake = FakeHttpConnection.new
    reporter = Quonfig::Telemetry::TelemetryReporter.new(
      options: make_options,
      instance_hash: 'h',
      context_shape_aggregator: Quonfig::Telemetry::ContextShapeAggregator.new(max_shapes: 10),
      http_connection: fake,
      sync_interval: 999 # avoid the background thread firing during the test
    )

    refute reporter.at_exit_registered?, 'not registered before start'
    reporter.start
    assert reporter.at_exit_registered?, 'registered after start'
  ensure
    reporter&.stop
  end
end
