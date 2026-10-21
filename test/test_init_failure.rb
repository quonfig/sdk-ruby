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
  def delivery_leg(status: 503, healthy_after: nil, delay: nil, body: nil, userinfo: nil)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    server = WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new(StringIO.new), AccessLog: [])
    @requests ||= Hash.new(0)
    server.mount_proc('/api/v2/configs') do |_req, res|
      @requests[server.config[:Port]] += 1
      sleep delay if delay
      age = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      if body
        res.status = status
        res.body = body
      elsif healthy_after && age >= healthy_after
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
    "http://#{"#{userinfo}@" if userinfo}127.0.0.1:#{server.config[:Port]}"
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
    assert_logged [/\[quonfig\] init FAILED: SDK key rejected \(401\) by primary and secondary\. .*raising now/]
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
    # D2: the secondary failed fast (refused), so the attempt did not hang.
    assert_equal :unavailable, err&.reason
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

  # A Client whose init backoff and progress cadence the test controls.
  def scripted_client_class(backoff: nil, progress_every: nil)
    Class.new(Quonfig::Client) do
      define_method(:init_backoff_s) { |attempt| backoff ? instance_exec(attempt, &backoff) : super(attempt) }
      define_method(:init_progress_every_s) { progress_every || super() }
    end
  end

  def test_details_getters_before_ready_report_provider_not_ready
    client = Quonfig::Client.new(**client_opts(api_urls: REFUSED, init_timeout_ms: 200, on_init_failure: :continue))
    details = client.get_string_details('missing.flag')

    assert_equal 'ERROR', details.reason
    assert_equal Quonfig::EvaluationDetails::ERROR_PROVIDER_NOT_READY, details.error_code
    assert_equal 'PROVIDER_NOT_READY', details.error_code
    assert_nil details.value
    assert_equal 'DEFAULT', client.get('flag.init', 'DEFAULT')
    assert_logged [/STARTING ON CODE DEFAULTS/]
  ensure
    client&.stop
  end

  def test_details_getters_after_heal_evaluate_normally
    leg = delivery_leg(healthy_after: 0.5)
    client = Quonfig::Client.new(**client_opts(api_urls: [leg], init_timeout_ms: 200, on_init_failure: :continue,
                                               enable_polling: true, fallback_poll_interval_ms: 100))
    assert client.wait_for_ready(timeout_ms: 5000)
    details = client.get_string_details('flag.init')
    assert_equal 'LIVE', details.value
    assert_nil details.error_code
    assert_logged [/init recovered/]
  ensure
    client&.stop
  end

  # Section C: progress every 5s (here 0.3s) until the timeout, even while
  # the SDK is sleeping a long backoff between attempts.
  def test_progress_warn_fires_on_its_cadence_during_a_long_backoff
    klass = scripted_client_class(backoff: ->(_a) { 0.9 }, progress_every: 0.3)
    assert_raises(Quonfig::Errors::InitializationError) do
      klass.new(**client_opts(api_urls: REFUSED, init_timeout_ms: 1000))
    end

    progress = $logs.string.lines.grep(/still waiting for config/)
    assert_operator progress.size, :>=, 2, progress.join
    assert_match(/still waiting for config \(0\.3s elapsed of 1s, attempt 1\)\. primary=/, progress.first)
    assert_logged [/still waiting for config/]
  end

  # :wait logs its timeout WARN at init_timeout_ms, not after the backoff
  # that happens to straddle it.
  def test_wait_timeout_warn_fires_at_the_deadline
    leg = delivery_leg(healthy_after: 1.2)
    klass = scripted_client_class(backoff: ->(_a) { 1.5 })
    client = klass.new(**client_opts(api_urls: [leg], init_timeout_ms: 500, on_init_failure: :wait))

    assert_predicate client, :ready?
    assert_logged [/init: no config after 0\.5s\. onInitFailure=wait: still blocking startup/]
  ensure
    client&.stop
  end

  def test_auth_line_names_the_single_leg
    err = begin
      Quonfig::Client.new(**client_opts(api_urls: [delivery_leg(status: 401)], init_timeout_ms: 4000))
      nil
    rescue Quonfig::Errors::InitializationError => e
      e
    end
    assert_equal :unauthorized, err&.reason
    assert_logged [/SDK key rejected \(401\) by primary\. Check the key/]
  end

  # The heal line names the leg. A stream install leaves resolved_from empty
  # and used to read "via stream".
  def test_heal_line_names_the_leg_for_a_stream_install
    client = Quonfig::Client.new(**client_opts(api_urls: REFUSED, init_timeout_ms: 100, on_init_failure: :continue))
    client.send(:log_init_recovered, Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1)

    assert_logged [/init recovered: config loaded after \d+\.\ds via primary\. Now serving live config/]
    refute_includes $logs.to_s, 'via stream'
  ensure
    client&.stop
  end

  # Structured loggers get event=quonfig.init.<name> (section C).
  def test_init_lines_carry_a_structured_event_name
    assert_raises(Quonfig::Errors::InitializationError) do
      Quonfig::Client.new(**client_opts(api_urls: REFUSED, init_timeout_ms: 300))
    end

    log = $logs.string
    assert_match(/init: config not loaded yet.*quonfig\.init\.retrying/, log)
    assert_match(/init FAILED: no config.*quonfig\.init\.failed/, log)
    assert_logged [/init FAILED/]
  end

  # D3 (qfg-9p4i.17): init_timeout_ms <= 0 runs exactly one attempt, lets it
  # finish, then applies on_init_failure. It never decides before the attempt.
  def test_zero_timeout_runs_one_full_attempt_and_installs_a_slow_success
    leg = delivery_leg(healthy_after: 0, delay: 0.3)
    client = Quonfig::Client.new(**client_opts(api_urls: [leg], init_timeout_ms: 0))

    assert_predicate client, :ready?
    assert_equal 'LIVE', client.get('flag.init', 'DEFAULT')
    assert_logged [/explicit api_urls disables automatic failover/]
  ensure
    client&.stop
  end

  def test_zero_timeout_fail_raises_unavailable_after_exactly_one_attempt
    leg = delivery_leg(status: 503, delay: 0.3)
    port = leg[/\d+\z/].to_i
    err = begin
      Quonfig::Client.new(**client_opts(api_urls: [leg], init_timeout_ms: 0))
      nil
    rescue Quonfig::Errors::InitializationError => e
      e
    end

    assert_equal :unavailable, err&.reason
    assert_match(/primary=127\.0\.0\.1:\d+: HTTP 503/, err.errors)
    sleep 0.2
    assert_equal 1, @requests[port], 'exactly one attempt'
    assert_logged [/init FAILED: no config after/]
  end

  def test_zero_timeout_continue_returns_on_defaults_after_one_attempt
    leg = delivery_leg(status: 503, delay: 0.2)
    client = Quonfig::Client.new(**client_opts(api_urls: [leg], init_timeout_ms: 0, on_init_failure: :continue))

    refute_predicate client, :ready?
    assert_equal 'DEFAULT', client.get('flag.init', 'DEFAULT')
    assert_logged [/onInitFailure=continue: STARTING ON CODE DEFAULTS/]
  ensure
    client&.stop
  end

  # D4: init log lines and the init error carry host:port and HTTP <status>,
  # never URL userinfo or upstream response bodies.
  def test_init_logs_and_error_never_carry_userinfo_or_upstream_bodies
    body = '{"error":"secret-upstream-detail token=abc"}'
    legs = [delivery_leg(status: 401, body: body, userinfo: 'alice:hunter2'),
            delivery_leg(status: 401, body: body, userinfo: 'alice:hunter2')]
    err = begin
      Quonfig::Client.new(**client_opts(api_urls: legs, init_timeout_ms: 4000))
      nil
    rescue Quonfig::Errors::InitializationError => e
      e
    end

    assert_equal :unauthorized, err&.reason
    log = $logs.string
    [err.message, err.errors, log].each do |text|
      refute_includes text, 'hunter2'
      refute_includes text, 'alice'
      refute_includes text, 'secret-upstream-detail'
    end
    assert_logged [/SDK key rejected \(401\) by primary and secondary/]
  end

  def test_non_json_200_body_never_reaches_the_init_error_or_logs
    leg = delivery_leg(status: 200, body: '<html>captive-portal-secret</html>', userinfo: 'alice:hunter2')
    err = begin
      Quonfig::Client.new(**client_opts(api_urls: [leg], init_timeout_ms: 600))
      nil
    rescue Quonfig::Errors::InitializationError => e
      e
    end

    refute_nil err
    [err.message, err.errors, $logs.string].each do |text|
      refute_includes text, 'captive-portal-secret'
      refute_includes text, 'hunter2'
    end
    assert_logged [/init FAILED/]
  end

  # The unauthorized line reports the primary's status, not whichever leg's
  # status happened to be recorded first.
  def test_unauthorized_reports_the_primary_status
    legs = [delivery_leg(status: 404, delay: 0.4), delivery_leg(status: 401)]
    err = begin
      Quonfig::Client.new(**client_opts(api_urls: legs, init_timeout_ms: 4000, config_fetch_hedge_delay_ms: 50))
      nil
    rescue Quonfig::Errors::InitializationError => e
      e
    end

    assert_equal :unauthorized, err&.reason
    assert_match(/SDK key rejected \(404\)/, err.message)
    assert_logged [/SDK key rejected \(404\) by primary and secondary/]
  end

  # An attempt cut off at the deadline keeps the leg errors it already had;
  # a fast-failed leg means the attempt did not hang (D2), so :unavailable.
  def test_cut_off_attempt_keeps_known_leg_errors
    legs = [delivery_leg(status: 503), hung_leg] # primary fails fast, secondary hangs
    err = begin
      Quonfig::Client.new(**client_opts(api_urls: legs, init_timeout_ms: 400, config_fetch_hedge_abort_ms: 600))
      nil
    rescue Quonfig::Errors::InitializationError => e
      e
    end

    assert_equal :unavailable, err&.reason
    assert_match(/primary=127\.0\.0\.1:\d+: HTTP 503; secondary=127\.0\.0\.1:\d+: no response before initTimeout/,
                 err.errors)
    assert_logged [/init FAILED/]
  ensure
    sleep 0.8 # let the hung leg's hedge abort settle
    $logs = nil
    @hung_server&.close
    @hung_thread&.kill
    @hung_sockets&.each(&:close)
  end

  def test_all_legs_hung_still_raises_timeout
    legs = [hung_leg]
    err = begin
      Quonfig::Client.new(**client_opts(api_urls: legs, init_timeout_ms: 300))
      nil
    rescue Quonfig::Errors::InitializationError => e
      e
    end

    assert_kind_of Quonfig::Errors::InitializationTimeoutError, err
    assert_logged [/init FAILED/]
  ensure
    @hung_server&.close
    @hung_thread&.kill
    @hung_sockets&.each(&:close)
  end

  # D2: a connect timeout is a hang, not a fast failure. Faraday's Net::HTTP
  # adapter wraps Net::OpenTimeout in ConnectionFailed, so a blackholed
  # delivery host must still raise :timeout, as sdk-go does for a dial timeout.
  def test_connect_timeout_counts_as_hung
    conn = Object.new
    def conn.get(*)
      raise Faraday::ConnectionFailed, Net::OpenTimeout.new('execution expired')
    end
    err = Quonfig::HttpConnection.stub(:new, ->(*_args, **_kw) { conn }) do
      Quonfig::Client.new(**client_opts(api_urls: ['http://10.255.255.1:443'], init_timeout_ms: 300))
      nil
    rescue Quonfig::Errors::InitializationError => e
      e
    end

    assert_kind_of Quonfig::Errors::InitializationTimeoutError, err
    assert_match(/primary=10\.255\.255\.1:443: timed out/, err.errors)
    assert_logged [/explicit api_urls disables automatic failover/, /init: config not loaded yet/, /init FAILED/]
  end

  # --- Decision 10 (qfg-9p4i.17.14): the deadline reason follows sdk-go ---

  # A leg that answers +status+ to its first +answers+ requests, then accepts
  # every later connection and never replies (a blackhole).
  def answers_then_hangs(status: 503, answers: 1)
    server = TCPServer.new('127.0.0.1', 0)
    @held_sockets ||= []
    @held_servers ||= []
    @held_threads ||= []
    served = 0
    @held_threads << Thread.new do
      loop do
        sock = server.accept
        if served < answers
          served += 1
          while (line = sock.gets) && line != "\r\n"; end
          sock.write("HTTP/1.1 #{status} Err\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
          sock.close
        else
          @held_sockets << sock
        end
      end
    rescue StandardError
      nil
    end
    @held_servers << server
    "http://127.0.0.1:#{server.addr[1]}"
  end

  # Hung legs log late WARNs on their own threads; the assertions above cover
  # what matters, so drop the capture before teardown checks it.
  def release_held_legs
    sleep 0.05
    $logs = nil
    @held_servers&.each { |s| s.close rescue nil } # rubocop:disable Style/RescueModifier
    @held_threads&.each(&:kill)
    @held_sockets&.each { |s| s.close rescue nil } # rubocop:disable Style/RescueModifier
  end

  # A backoff after attempt 1 that leaves +left_s+ before the deadline, then a
  # backoff long enough that the deadline always lands inside it.
  def backoff_leaving(left_s)
    lambda do |attempt|
      next 10.0 unless attempt == 1

      deadline = @init_started_at + (@options.init_timeout_ms / 1000.0)
      [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC) - left_s, 0].max
    end
  end

  def init_error
    yield
    nil
  rescue Quonfig::Errors::InitializationError => e
    e
  end

  # (1) Attempt 1 fails fast (503). With time left before the deadline a new
  # attempt starts, as in sdk-go, even with under 250ms left; it is
  # blackholed, so it is in flight at the deadline with no leg answered: the
  # reason is :timeout, whatever attempt 1 did.
  def test_later_attempt_blackholed_until_the_deadline_raises_timeout
    klass = scripted_client_class(backoff: backoff_leaving(0.15))
    err = init_error { klass.new(**client_opts(api_urls: [answers_then_hangs], init_timeout_ms: 600)) }

    assert_kind_of Quonfig::Errors::InitializationTimeoutError, err
    assert_equal :timeout, err.reason
    assert_match(/primary=127\.0\.0\.1:\d+: no response before initTimeout/, err.errors)
  ensure
    release_held_legs
  end

  # Scheduling: a fast-failing outage keeps starting attempts while time
  # remains, even with under 250ms left, and stays :unavailable.
  def test_new_attempt_starts_whenever_time_remains_before_the_deadline
    leg = delivery_leg(status: 503)
    port = Integer(leg[/:(\d+)\z/, 1])
    klass = scripted_client_class(backoff: backoff_leaving(0.15))
    err = init_error { klass.new(**client_opts(api_urls: [leg], init_timeout_ms: 600)) }

    assert_equal 2, @requests[port]
    refute_kind_of Quonfig::Errors::InitializationTimeoutError, err
    assert_equal :unavailable, err.reason
    assert_logged [/explicit api_urls disables automatic failover/, /init: config not loaded yet/, /init FAILED/]
  end

  # (2) The deadline cuts attempt 1: the primary failed fast and the secondary
  # hangs. One leg answered, so the attempt did not hang: :unavailable.
  def test_deadline_cutting_attempt_one_with_a_fast_failed_leg_raises_unavailable
    legs = [delivery_leg(status: 503), answers_then_hangs(answers: 0)]
    err = init_error do
      Quonfig::Client.new(**client_opts(api_urls: legs, init_timeout_ms: 400, config_fetch_hedge_delay_ms: 50,
                                        config_fetch_hedge_abort_ms: 2000))
    end

    refute_kind_of Quonfig::Errors::InitializationTimeoutError, err
    assert_equal :unavailable, err.reason
    assert_match(/primary=127\.0\.0\.1:\d+: HTTP 503; secondary=127\.0\.0\.1:\d+: no response before initTimeout/,
                 err.errors)
  ensure
    release_held_legs
  end

  # (3) The deadline lands in the backoff after an attempt whose primary
  # answered (401 or 503) while the secondary timed out. That attempt did not
  # hang, so the reason is :unavailable.
  [401, 503].each do |status|
    define_method(:"test_deadline_in_backoff_after_primary_#{status}_and_secondary_timeout_raises_unavailable") do
      legs = [delivery_leg(status: status), answers_then_hangs(answers: 0)]
      klass = scripted_client_class(backoff: ->(_attempt) { 10.0 })
      err = init_error do
        klass.new(**client_opts(api_urls: legs, init_timeout_ms: 800, config_fetch_hedge_delay_ms: 50,
                                config_fetch_hedge_abort_ms: 200))
      end

      refute_kind_of Quonfig::Errors::InitializationTimeoutError, err
      assert_equal :unavailable, err.reason
      assert_match(/primary=127\.0\.0\.1:\d+: HTTP #{status}[^;]*; secondary=127\.0\.0\.1:\d+: timed out/, err.errors)
    ensure
      release_held_legs
    end
  end

  # (4) Every leg hangs throughout, across attempts that complete on the hedge
  # abort and the one the deadline cuts: :timeout.
  def test_all_legs_hung_throughout_raises_timeout
    legs = [answers_then_hangs(answers: 0), answers_then_hangs(answers: 0)]
    err = init_error do
      Quonfig::Client.new(**client_opts(api_urls: legs, init_timeout_ms: 900, config_fetch_hedge_delay_ms: 50,
                                        config_fetch_hedge_abort_ms: 200))
    end

    assert_kind_of Quonfig::Errors::InitializationTimeoutError, err
    assert_equal :timeout, err.reason
  ensure
    release_held_legs
  end
end
