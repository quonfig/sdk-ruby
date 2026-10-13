# frozen_string_literal: true

require 'test_helper'
require 'webrick'
require 'socket'
require 'json'
require 'tmpdir'
require 'fileutils'

# qfg-goi1.2.35 (A) — telemetry must snapshot the caller's context at record
# time. The example-contexts aggregator kept the caller's nested Hash/Array by
# reference and serialized it later on the reporter thread, so a caller
# mutation after get() changed (or broke) what was sent. A NaN, or a context
# value that contains itself, made JSON.generate raise and the whole window
# (summaries, shapes, examples) was lost (ruby L9).
#
# Public path: a real datadir Client, Client#get, then Client#stop flushes to a
# real local capture server.
class TestTelemetryContextSnapshot < Minitest::Test
  # A value type that is not JSON-native but renders as a string, like a UUID
  # object. Its rendering must still reach the example context.
  class FakeUuid
    def initialize(str) = @str = str
    def to_s = @str
  end

  def setup
    super
    @telemetry_posts = []
    @workspace = Dir.mktmpdir('quonfig-context-snapshot')
    FileUtils.mkdir_p(File.join(@workspace, 'configs'))
    File.write(File.join(@workspace, 'quonfig.json'), JSON.generate({ environments: ['Production'] }))
    File.write(File.join(@workspace, 'configs', 'greeting.json'), JSON.generate(greeting_config))
    @server = start_capture_server
    @client = Quonfig::Client.new(
      sdk_key: 'qf_sk_dev_abc_deadbeef', datadir: @workspace, environment: 'Production',
      telemetry_url: "http://127.0.0.1:#{@port}", enable_sse: false, fallback_poll_enabled: false,
      collect_sync_interval: 3600
    )
  end

  def teardown
    @client&.stop
    @server&.shutdown
    FileUtils.remove_entry(@workspace) if @workspace && Dir.exist?(@workspace)
    super
  end

  def test_example_context_keeps_call_time_nested_values
    nested = { 'plan' => 'free', 'tags' => %w[a b] }
    assert_equal 'hi', @client.get('greeting', nil, { 'user' => { 'key' => 'u1', 'meta' => nested } })
    nested['plan'] = 'mutated'
    nested['tags'] << 'mutated'
    nested['extra'] = 'added-later'

    values = flushed_example_values('user')
    assert_equal({ 'plan' => 'free', 'tags' => %w[a b] }, values['meta'])
  end

  def test_nan_and_infinity_do_not_drop_the_window
    assert_equal 'hi', @client.get('greeting', nil, { 'user' => { 'key' => 'u1', 'score' => Float::NAN,
                                                                  'max' => Float::INFINITY } })
    payload = flushed_payload
    assert(payload['events'].any? { |e| e['summaries'] }, 'summaries event lost')
    values = example_values(payload, 'user')
    assert_nil values['score']
    assert_nil values['max']
    assert_equal 'u1', values['key']
  end

  def test_self_referential_context_value_does_not_drop_the_window
    loop_hash = { 'name' => 'loop' }
    loop_hash['self'] = loop_hash
    assert_equal 'hi', @client.get('greeting', nil, { 'user' => { 'key' => 'u1', 'loop' => loop_hash } })
    payload = flushed_payload
    assert(payload['events'].any? { |e| e['summaries'] }, 'summaries event lost')
    assert_equal({ 'name' => 'loop' }, example_values(payload, 'user')['loop'])
  end

  def test_string_rendered_value_type_key_and_list_reach_example_context
    id = FakeUuid.new('6f1c2a9e-0000-4000-8000-000000000001')
    assert_equal 'hi', @client.get('greeting', nil, { 'user' => { 'key' => id, 'ids' => [1, 2] } })
    values = flushed_example_values('user')
    assert_equal '6f1c2a9e-0000-4000-8000-000000000001', values['key']
    assert_equal [1, 2], values['ids']
  end

  private

  def greeting_config
    {
      'id' => 'cfg-1', 'key' => 'greeting', 'type' => 'config', 'valueType' => 'string',
      'sendToClientSdk' => false,
      'default' => { 'rules' => [{ 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
                                   'value' => { 'type' => 'string', 'value' => 'hi' } }] }
    }
  end

  def flushed_payload
    @client.stop
    @client = nil
    refute_empty @telemetry_posts, 'expected a telemetry POST'
    JSON.parse(@telemetry_posts.last)
  end

  def flushed_example_values(type)
    example_values(flushed_payload, type)
  end

  def example_values(payload, type)
    examples = payload['events'].filter_map { |e| e['exampleContexts'] }.first
    refute_nil examples, "no exampleContexts event in #{payload['events'].inspect}"
    ctx = examples['examples'][0]['contextSet']['contexts'].find { |c| c['type'] == type }
    refute_nil ctx
    ctx['values']
  end

  def start_capture_server
    server = WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new(StringIO.new), AccessLog: [])
    server.mount_proc '/api/v1/telemetry/' do |req, res|
      @telemetry_posts << req.body
      res.status = 200
      res['Content-Type'] = 'application/json'
      res.body = '{}'
    end
    @port = server.config[:Port]
    Thread.new { server.start }
    50.times do
      TCPSocket.new('127.0.0.1', @port).close
      break
    rescue StandardError
      sleep 0.05
    end
    server
  end
end
