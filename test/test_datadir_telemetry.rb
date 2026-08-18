# frozen_string_literal: true

require 'test_helper'
require 'webrick'
require 'socket'
require 'json'
require 'tmpdir'
require 'fileutils'

# qfg-5x9x — datadir mode must NOT disable telemetry. The gate is SDK-KEY
# PRESENCE, not mode: datadir + a valid SDK key is a supported combination and
# usage telemetry has to flow there exactly as it does in delivery mode, while
# a keyless client (the open-source / no-account path) must emit nothing at all
# because there is no workspace to attribute the data to.
#
# Both directions are asserted here, mirroring sdk-node's
# test/datadir-telemetry.test.ts (the reference implementation) and the sdk-go /
# sdk-python ports made for qfg-j001. The with-key half is the one sdk-ruby got
# wrong: Options#telemetry_allowed? zeroed every collect_max_* in datadir mode,
# so Client#initialize_telemetry built no aggregators and never constructed a
# reporter.
#
# These drive a REAL Client against a REAL local capture server, so a pass means
# the bytes actually left (or did not leave) the SDK — a stubbed reporter would
# not prove that.
class TestDatadirTelemetry < Minitest::Test
  def setup
    super
    @clients = []
    @telemetry_posts = []
    @workspace = Dir.mktmpdir('quonfig-datadir-telemetry')
    FileUtils.mkdir_p(File.join(@workspace, 'configs'))
    File.write(
      File.join(@workspace, 'quonfig.json'),
      JSON.generate({ environments: ['Production'] })
    )
    File.write(
      File.join(@workspace, 'configs', 'welcome-message.config.json'),
      JSON.generate(welcome_message_config)
    )
    @server = start_capture_server
  end

  def teardown
    @clients.each do |c|
      c.stop
    rescue StandardError
      nil
    end
    begin
      @server&.shutdown
    rescue StandardError
      nil
    end
    FileUtils.remove_entry(@workspace) if @workspace && Dir.exist?(@workspace)
    super
  end

  def welcome_message_config
    {
      'id' => 'cfg-1',
      'key' => 'welcome-message',
      'type' => 'config',
      'valueType' => 'string',
      'sendToClientSdk' => false,
      'default' => {
        'rules' => [
          { 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
            'value' => { 'type' => 'string', 'value' => 'hello' } }
        ]
      },
      'environments' => [
        { 'id' => 'Production',
          'rules' => [
            { 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
              'value' => { 'type' => 'string', 'value' => 'hola' } }
          ] }
      ]
    }
  end

  def start_capture_server
    log = WEBrick::Log.new(StringIO.new)
    server = WEBrick::HTTPServer.new(Port: 0, Logger: log, AccessLog: [])
    server.mount_proc '/api/v1/telemetry/' do |req, res|
      @telemetry_posts << { body: req.body, auth: req['Authorization'] }
      res.status = 200
      res['Content-Type'] = 'application/json'
      res.body = '{}'
    end
    @port = server.config[:Port]
    Thread.new { server.start }
    50.times do
      break if tcp_open?(@port)

      sleep 0.05
    end
    server
  end

  def tcp_open?(port)
    TCPSocket.new('127.0.0.1', port).tap(&:close)
    true
  rescue StandardError
    false
  end

  def telemetry_url
    "http://127.0.0.1:#{@port}"
  end

  def build_datadir_client(sdk_key:)
    client = Quonfig::Client.new(
      sdk_key: sdk_key,
      datadir: @workspace,
      environment: 'Production',
      telemetry_url: telemetry_url,
      enable_sse: false,
      fallback_poll_enabled: false,
      # Long enough that the periodic loop never fires on its own — the drain
      # under test is the one Client#stop performs.
      collect_sync_interval: 3600
    )
    @clients << client
    client
  end

  # THE BUG (qfg-5x9x): a datadir client holding a perfectly valid SDK key sent
  # nothing at all. Every collect_max_* was forced to 0 by the mode-based gate,
  # so no aggregator — and therefore no reporter — was ever built.
  def test_datadir_with_sdk_key_emits_telemetry
    client = build_datadir_client(sdk_key: 'qf_sk_dev_abc_deadbeef')

    assert_equal 'hola', client.get('welcome-message')

    refute_nil client.telemetry_reporter,
               'datadir + valid SDK key must construct a telemetry reporter'

    client.stop

    assert_equal 1, @telemetry_posts.size,
                 "datadir + valid SDK key must POST telemetry; got #{@telemetry_posts.size} POST(s)"

    payload = JSON.parse(@telemetry_posts.first[:body])
    summaries = payload['events'].filter_map { |e| e['summaries'] }.first

    refute_nil summaries, "expected a summaries event in #{payload['events'].inspect}"
    assert_includes summaries['summaries'].map { |s| s['key'] }, 'welcome-message'
  end

  # The opposite direction, held by the same gate: no SDK key means no workspace
  # to attribute telemetry to, so the SDK must not even build the aggregators.
  # (Guards against over-rotating the fix into "datadir always sends".)
  def test_datadir_without_sdk_key_emits_nothing
    client = build_datadir_client(sdk_key: nil)

    assert_equal 'hola', client.get('welcome-message')

    assert_nil client.telemetry_reporter,
               'keyless datadir client must not construct a telemetry reporter'

    client.stop

    assert_empty @telemetry_posts,
                 "keyless datadir client must POST nothing; got #{@telemetry_posts.inspect}"
  end

  # Options-level gate, asserted directly: presence of the SDK key is the only
  # thing that decides whether collection is allowed. Datadir is irrelevant.
  def test_telemetry_gate_is_sdk_key_presence_not_datadir
    keyed_datadir = Quonfig::Options.new(sdk_key: 'qf_sk_dev_abc_deadbeef', datadir: '/tmp/ws')

    assert_operator keyed_datadir.collect_max_evaluation_summaries, :>, 0
    assert_operator keyed_datadir.collect_max_example_contexts, :>, 0
    assert_operator keyed_datadir.collect_max_shapes, :>, 0
    assert_operator keyed_datadir.collect_max_paths, :>, 0

    keyless_datadir = Quonfig::Options.new(sdk_key: nil, datadir: '/tmp/ws')

    assert_equal 0, keyless_datadir.collect_max_evaluation_summaries
    assert_equal 0, keyless_datadir.collect_max_example_contexts
    assert_equal 0, keyless_datadir.collect_max_shapes
    assert_equal 0, keyless_datadir.collect_max_paths

    keyless_delivery = Quonfig::Options.new(sdk_key: nil)

    assert_equal 0, keyless_delivery.collect_max_evaluation_summaries
    assert_equal 0, keyless_delivery.collect_max_example_contexts
    assert_equal 0, keyless_delivery.collect_max_shapes
    assert_equal 0, keyless_delivery.collect_max_paths
  end

  # `allow_telemetry_in_local_mode:` is retained as an accepted no-op so callers
  # that passed it keep working; it can neither enable telemetry without a key
  # nor suppress it with one.
  def test_allow_telemetry_in_local_mode_is_an_accepted_no_op
    with_flag = Quonfig::Options.new(
      sdk_key: 'qf_sk_dev_abc_deadbeef', datadir: '/tmp/ws', allow_telemetry_in_local_mode: true
    )
    without_flag = Quonfig::Options.new(sdk_key: 'qf_sk_dev_abc_deadbeef', datadir: '/tmp/ws')

    assert_equal without_flag.collect_max_evaluation_summaries,
                 with_flag.collect_max_evaluation_summaries

    keyless = Quonfig::Options.new(sdk_key: nil, datadir: '/tmp/ws', allow_telemetry_in_local_mode: true)

    assert_equal 0, keyless.collect_max_evaluation_summaries
  end
end
