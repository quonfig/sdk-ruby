# frozen_string_literal: true

require 'test_helper'
require 'webrick'
require 'json'
require 'socket'

# on_init_failure :fail / :wait / :continue, the readiness API, the
# InitializationError family and the init log contract (qfg-9p4i.10;
# project/plans/2026-10-05-init-failure-design.md B.1-B.4, C).
class TestInitFailure < Minitest::Test
  CONFIG = {
    'id' => 'c1',
    'key' => 'flag.init',
    'type' => 'config',
    'valueType' => 'string',
    'sendToClientSdk' => false,
    'default' => {
      'rules' => [
        { 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }], 'value' => { 'type' => 'string', 'value' => 'LIVE' } }
      ]
    }
  }.freeze

  REFUSED = ['http://127.0.0.1:1', 'http://127.0.0.1:2'].freeze

  def setup
    super
    @servers = []
  end

  def teardown
    @servers.each(&:shutdown)
    super
  end

  # A delivery leg that answers +status+ until +healthy_after+ seconds have
  # passed since it started, then serves CONFIG.
  def delivery_leg(status: 503, healthy_after: nil)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    server = WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new(StringIO.new), AccessLog: [])
    server.mount_proc('/api/v2/configs') do |_req, res|
      age = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      if healthy_after && age >= healthy_after
        res.status = 200
        res['Content-Type'] = 'application/json'
        res.body = JSON.generate('configs' => [CONFIG], 'meta' => { 'version' => 'v1', 'environment' => 'dev',
                                                                    'generation' => 1 })
      else
        res.status = status
      end
    end
    Thread.new { server.start }
    @servers << server
    "http://127.0.0.1:#{server.config[:Port]}"
  end

  def client_opts(**overrides)
    { sdk_key: 'SECRET-SDK-KEY-123', enable_sse: false, enable_polling: false,
      context_upload_mode: :none, collect_evaluation_summaries: false,
      enable_quonfig_user_context: false }.merge(overrides)
  end

  def timed
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    [result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - start]
  end

  def test_canonical_values_and_aliases_resolve
    m = Quonfig::Options::ON_INITIALIZATION_FAILURE
    assert_equal :fail, Quonfig::Options.new.on_init_failure, 'fail is the default'
    assert_equal :fail, Quonfig::Options.new(on_init_failure: :raise).on_init_failure
    assert_equal :raise, Quonfig::Options.new(on_init_failure: :raise).on_init_failure_alias
    assert_equal :continue, Quonfig::Options.new(on_init_failure: :return).on_init_failure
    assert_equal :wait, Quonfig::Options.new(on_init_failure: 'wait').on_init_failure
    assert_equal [:fail, nil, :bogus], m.resolve(:bogus)
    assert_equal %i[fail wait continue], [m::FAIL, m::WAIT, m::CONTINUE]
  end

  def test_error_family
    assert_operator Quonfig::Errors::InitializationError, :<, Quonfig::Error
    assert_operator Quonfig::Errors::InitializationTimeoutError, :<, Quonfig::Errors::InitializationError
    assert_equal :timeout, Quonfig::Errors::InitializationTimeoutError.new(1, nil).reason
  end

  def test_fail_retries_until_the_timeout_then_raises_unavailable_with_per_leg_errors
    err, elapsed = timed do
      Quonfig::Client.new(**client_opts(api_urls: REFUSED, init_timeout_ms: 1200))
      nil
    rescue Quonfig::Errors::InitializationError => e
      e
    end

    refute_nil err
    refute_kind_of Quonfig::Errors::InitializationTimeoutError, err
    assert_equal :unavailable, err.reason
    assert_operator elapsed, :>=, 1.1, 'fail retries through blips until init_timeout_ms'
    assert_match(/primary=127\.0\.0\.1:1: .+; secondary=127\.0\.0\.1:2: /, err.errors)
    refute_includes err.message, 'SECRET-SDK-KEY-123'
    log = $logs.string
    refute_includes log, 'SECRET-SDK-KEY-123'
    assert_logged [
      /\[quonfig\] init: config not loaded yet, retrying until initTimeout \(1\.2s\)\. primary=127\.0\.0\.1:1/,
      /\[quonfig\] init FAILED: no config after 1\.2s\. primary=.*onInitFailure=fail: raising/
    ]
  end

  def test_fail_raises_at_once_when_every_leg_rejects_the_key
    legs = [delivery_leg(status: 401), delivery_leg(status: 401)]
    err, elapsed = timed do
      Quonfig::Client.new(**client_opts(api_urls: legs, init_timeout_ms: 8000))
      nil
    rescue Quonfig::Errors::InitializationError => e
      e
    end

    assert_equal :unauthorized, err&.reason
    assert_operator elapsed, :<, 4
    assert_logged [/\[quonfig\] init FAILED: SDK key rejected \(401\) by every delivery leg\. .*raising now/]
  end

  def test_wait_blocks_past_the_timeout_until_delivery_returns
    leg = delivery_leg(healthy_after: 1.5)
    client, elapsed = timed do
      Quonfig::Client.new(**client_opts(api_urls: [leg], init_timeout_ms: 300, on_init_failure: :wait))
    end

    assert_operator elapsed, :>=, 1.4, 'wait keeps blocking past init_timeout_ms'
    assert_predicate client, :ready?
    assert_equal 'LIVE', client.get('flag.init', 'DEFAULT')
    assert_logged [
      /\[quonfig\] init: no config after \d+\.\ds\. onInitFailure=wait: still blocking startup/,
      /\[quonfig\] init recovered: config loaded after \d+\.\ds via primary \(version v1\)/
    ]
  ensure
    client&.stop
  end

  def test_continue_returns_at_the_timeout_and_heals_in_the_background
    leg = delivery_leg(healthy_after: 1.0)
    client, elapsed = timed do
      Quonfig::Client.new(**client_opts(api_urls: [leg], init_timeout_ms: 300, on_init_failure: :continue,
                                        enable_polling: true, fallback_poll_interval_ms: 200))
    end

    assert_operator elapsed, :<, 1.0
    refute_predicate client, :ready?
    assert_equal 'DEFAULT', client.get('flag.init', 'DEFAULT')
    assert client.wait_for_ready(timeout_ms: 5000), 'the background retry heals the client'
    assert_equal 'LIVE', client.get('flag.init', 'DEFAULT')
    assert_logged [
      /\[quonfig\] init: no config after 0\.3s\. onInitFailure=continue: STARTING ON CODE DEFAULTS/,
      /\[quonfig\] init recovered: config loaded after \d+\.\ds/
    ]
  ensure
    client&.stop
  end

  def test_continue_starts_at_once_when_every_leg_rejects_the_key
    legs = [delivery_leg(status: 403), delivery_leg(status: 403)]
    client, elapsed = timed do
      Quonfig::Client.new(**client_opts(api_urls: legs, init_timeout_ms: 8000, on_init_failure: :continue))
    end

    assert_operator elapsed, :<, 4
    refute_predicate client, :ready?
    assert_logged [/\[quonfig\] init FAILED: SDK key rejected \(403\).*onInitFailure=continue/]
  ensure
    client&.stop
  end

  def test_wait_for_ready_returns_false_when_the_timeout_runs_out
    client = Quonfig::Client.new(**client_opts(api_urls: REFUSED, init_timeout_ms: 200, on_init_failure: :continue))
    _ready, elapsed = timed { refute client.wait_for_ready(timeout_ms: 300) }
    assert_operator elapsed, :>=, 0.25
    client.stop
    refute client.wait_for_ready, 'a stopped client never becomes ready'
    assert_logged [/STARTING ON CODE DEFAULTS/]
  end

  # A leg that accepts the connection and never answers.
  def hung_leg
    server = TCPServer.new('127.0.0.1', 0)
    @hung_sockets = []
    @hung_thread = Thread.new do
      loop { @hung_sockets << server.accept }
    rescue StandardError
      nil
    end
    @hung_server = server
    "http://127.0.0.1:#{server.addr[1]}"
  end

  # An attempt still in flight at the timeout keeps its legs running until the
  # hedge abort. Their late failures must not surface as WARNs after Client.new
  # has already raised (they leaked into the next test's log capture on CI).
  def test_hung_attempt_legs_do_not_log_after_init_raised
    legs = [hung_leg, 'http://127.0.0.1:1']
    err = begin
      Quonfig::Client.new(**client_opts(api_urls: legs, init_timeout_ms: 200, config_fetch_hedge_delay_ms: 50,
                                        config_fetch_hedge_abort_ms: 600))
      nil
    rescue Quonfig::Errors::InitializationError => e
      e
    end
    assert_kind_of Quonfig::Errors::InitializationTimeoutError, err
    $logs.truncate(0)
    $logs.rewind
    sleep 1.0 # past the 600ms hedge abort of the hung primary leg

    late = $logs.string.lines.grep(/ W |ConfigLoader.* E /)
    assert_empty late, "late leg WARNs after init raised: #{late}"
  ensure
    @hung_server&.close
    @hung_thread&.kill
    @hung_sockets&.each(&:close)
  end

  def test_deprecated_alias_warns_once_per_process
    Quonfig::Client.send(:const_get, :DEPRECATED_INIT_FAILURE_WARNED).clear
    2.times do
      Quonfig::Client.new(**client_opts(api_urls: REFUSED, init_timeout_ms: 100, on_init_failure: :return)).stop
    end

    assert_equal 1, $logs.string.scan('on_init_failure=:return is deprecated; use :continue').size
    assert_logged [/on_init_failure=:return is deprecated; use :continue/]
  end
end
