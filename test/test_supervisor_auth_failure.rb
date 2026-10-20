# frozen_string_literal: true

require 'test_helper'
require 'json'

# Tier 1 supervisor contract, Test 8: auth-class response (qfg-goi1.10.26).
# Contract: integration-test-data chaos/supervisor-test-contract.md Test 8
# (a)-(g) at v2026.10.16. Rule: project/plans/2026-10-07-sdk-auth-failure-rule.md
# section 4 (R1-R6).
#
# The rig follows the contract's fixture rules: the SSE worker and the config
# fetch legs are fakes, time is compressed, and everything else (the SSE
# reconnect loop, the fallback-poller schedule, the auth-failed state machine)
# is the real code.
#
# - Fake SSE: Net::HTTP.new for the stream host returns a FakeHTTP whose
#   response is scripted per connect attempt (a status, or :ok_fin = deliver one
#   envelope then FIN, or :ok_hold = deliver one envelope and stay open). The
#   real SSEConfigClient status handling and ladder run on top of it.
# - Fake fetch: Quonfig::HttpConnection.new for the two leg hosts returns a
#   FakeConn scripted per (cycle, leg). A cycle starts when the primary leg is
#   asked; cycle 0 is the init fetch.
# - Wait hook: Quonfig::Waits.hook sees every background wait (sse, engage,
#   poll, probe), records the requested value, and returns it 2000x smaller.
#
# All of it lands in one ordered event log (waits, leg hits with the client's
# connection_state at that moment, log lines), and the assertions cut that log
# at the entry ERROR and the exit INFO.
class TestSupervisorAuthFailure < Minitest::Test
  AUTH_STATUSES = [401, 403, 404, 410].freeze
  SCALE = 2000.0
  ENGAGE_WALL_SECONDS = 1.0
  PRIMARY = 'http://primary.authrig.test'
  SECONDARY = 'http://secondary.authrig.test'
  STREAM_HOST = 'stream.primary.authrig.test'
  # The SSE ladder the real SSEConfigClient requests after a healthy session
  # ends: 1s, then doubling to the 30s cap.
  SSE_LADDER_AFTER_HEALTHY = [1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0, 30.0, 30.0, 30.0].freeze
  # A brand-new SSE client whose first attempt fails asks for 2s first.
  SSE_FIRST_FAILURE_WAIT = 2.0
  ENTRY = /config fetch rejected/i
  EXIT = /leaving auth-failed/i

  # Logger-shaped sink that writes into the rig's ordered event log.
  class RigLogger
    def initialize(rig)
      @rig = rig
    end

    %i[debug info warn error].each do |level|
      define_method(level) do |msg = nil, &block|
        @rig.record(:log, level, (msg || block&.call).to_s)
      end
    end
  end

  class Rig
    Response = Struct.new(:status, :headers, :body)

    class << self
      attr_accessor :current
    end

    attr_reader :logger
    attr_accessor :client

    # sse_script: ->(attempt, rig) { Integer status | :ok_fin | :ok_hold }
    # fetch_script: ->(cycle, leg, rig) { Integer status | :timeout }
    def initialize(sse_script:, fetch_script:)
      @sse_script = sse_script
      @fetch_script = fetch_script
      @events = []
      @mutex = Mutex.new
      @cycle = -1
      @sse_attempt = -1
      @logger = RigLogger.new(self)
    end

    def record(*event)
      @mutex.synchronize { @events << event }
    end

    def events
      @mutex.synchronize { @events.dup }
    end

    def exited?
      events.any? { |e| e[0] == :log && e[1] == :info && e[2].match?(EXIT) }
    end

    def entered?
      events.any? { |e| e[0] == :log && e[1] == :error && e[2].match?(ENTRY) }
    end

    def leg_hit(leg)
      state = client&.connection_state
      terminal = client&.terminal_failure?
      cycle = @mutex.synchronize do
        @cycle += 1 if leg.zero?
        c = [@cycle, 0].max
        @events << [:hit, leg, c, state, terminal]
        c
      end
      [cycle, @fetch_script.call(cycle, leg, self)]
    end

    def sse_hit
      attempt = @mutex.synchronize { @sse_attempt += 1 }
      action = @sse_script.call(attempt, self)
      record(:sse, attempt, action)
      [attempt, action]
    end

    def leg_for(uri)
      s = uri.to_s
      return 0 if s.start_with?(PRIMARY)
      return 1 if s.start_with?(SECONDARY)

      nil
    end
  end

  def self.envelope_json(gen)
    JSON.generate('configs' => [],
                  'meta' => { 'version' => "g#{gen}", 'environment' => 'production', 'generation' => gen })
  end

  # Fake config fetch leg.
  class FakeConn
    def initialize(rig, leg)
      @rig = rig
      @leg = leg
    end

    def get(_path, _headers = {})
      cycle, status = @rig.leg_hit(@leg)
      raise Faraday::TimeoutError, 'fake leg timeout' if status == :timeout

      gen = 100 + cycle
      if status == 200
        Rig::Response.new(200, { 'ETag' => "g#{gen}" }, TestSupervisorAuthFailure.envelope_json(gen))
      else
        Rig::Response.new(status, {}, '')
      end
    end
  end

  # Fake SSE transport (Net::HTTP for the stream host).
  class FakeHTTP
    attr_accessor :use_ssl, :open_timeout, :read_timeout

    def initialize(rig)
      @rig = rig
      @started = false
      @finished = false
    end

    def start
      @started = true
      self
    end

    def started?
      @started
    end

    def finish
      @finished = true
      @started = false
    end

    def finished?
      @finished
    end

    def request(_req)
      attempt, action = @rig.sse_hit
      yield FakeSSEResponse.new(self, attempt, action)
    end
  end

  class FakeSSEResponse
    def initialize(http, attempt, action)
      @http = http
      @attempt = attempt
      @action = action
    end

    def code
      (@action.is_a?(Integer) ? @action : 200).to_s
    end

    def read_body
      yield "id: e#{@attempt}\ndata: #{TestSupervisorAuthFailure.envelope_json(50)}\n\n"
      return if @action == :ok_fin

      sleep 0.002 until @http.finished?
    end
  end

  # Route .new for the fake hosts to the fakes, for one test only. Installed
  # per test and removed in teardown (a global prepend collides with other
  # tests' Minitest stubs of the same method).
  def route_new(klass, &fake_for)
    own = klass.singleton_class.method_defined?(:new, false) ||
          klass.singleton_class.private_method_defined?(:new, false)
    orig = klass.method(:new)
    # Remove before redefining so `ruby -w` has no redefinition warning.
    klass.singleton_class.send(:remove_method, :new) if own
    klass.define_singleton_method(:new) do |*args, **kwargs, &block|
      fake = fake_for.call(args)
      next fake if fake

      orig.call(*args, **kwargs, &block)
    end
    (@routed ||= []) << [klass, own, orig]
  end

  def unroute_all
    (@routed || []).reverse_each do |klass, own, orig|
      klass.singleton_class.send(:remove_method, :new)
      klass.define_singleton_method(:new, orig) if own
    end
    @routed = []
  end

  def teardown
    @client&.stop
    Quonfig::Waits.hook = nil if Quonfig.const_defined?(:Waits)
    unroute_all
    Rig.current = nil
    Quonfig::InternalLogger.user_logger = nil
    super
  end

  # ------------------------------------------------------------------
  # rig helpers
  # ------------------------------------------------------------------

  def start_client(sse_script:, fetch_script:, enable_sse: true, poll_ms: nil)
    @rig = Rig.new(sse_script: sse_script, fetch_script: fetch_script)
    Rig.current = @rig
    rig = @rig
    route_new(Net::HTTP) { |args| FakeHTTP.new(rig) if args.first == STREAM_HOST }
    route_new(Quonfig::HttpConnection) do |args|
      leg = rig.leg_for(args.first)
      FakeConn.new(rig, leg) if leg
    end
    if Quonfig.const_defined?(:Waits)
      Quonfig::Waits.hook = lambda do |kind, seconds|
        rig.record(:wait, kind.to_sym, seconds.to_f)
        # Each real SSE attempt costs up to ~0.25s of watchdog join, so the
        # engage grace gets a full second of wall clock: enough for several
        # attempts on the ladder before the poller's first cycle.
        kind.to_sym == :engage ? ENGAGE_WALL_SECONDS : seconds / SCALE
      end
    end
    opts = {
      sdk_key: 'rig-sdk-key-not-real',
      api_urls: [PRIMARY, SECONDARY],
      environment: nil,
      enable_sse: enable_sse,
      logger: @rig.logger,
      on_init_failure: Quonfig::Options::ON_INITIALIZATION_FAILURE::CONTINUE,
      init_timeout_ms: 8000,
      context_upload_mode: :none,
      collect_evaluation_summaries: false,
      enable_quonfig_user_context: false
    }
    opts[:fallback_poll_interval_ms] = poll_ms if poll_ms
    @client = Quonfig::Client.new(**opts)
    @rig.client = @client
    @client
  end

  def wait_until(desc, timeout: 8)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "timed out after #{timeout}s waiting for: #{desc}\nevents:\n#{dump(@rig.events)}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.005
    end
  end

  def dump(events)
    events.last(80).map(&:inspect).join("\n")
  end

  def entry_index(events)
    events.index { |e| e[0] == :log && e[1] == :error && e[2].match?(ENTRY) }
  end

  def exit_index(events)
    events.index { |e| e[0] == :log && e[1] == :info && e[2].match?(EXIT) }
  end

  def waits(events, kind)
    events.select { |e| e[0] == :wait && e[1] == kind }.map { |e| e[2] }
  end

  def hits(events, leg = nil)
    events.select { |e| e[0] == :hit && (leg.nil? || e[1] == leg) }
  end

  def logs(events, level, pattern = /.*/)
    events.select { |e| e[0] == :log && e[1] == level && e[2].match?(pattern) }
  end

  def primary_cycles(events)
    hits(events, 0).size
  end

  # Mid-life drop: SSE delivers one envelope then FINs; every later attempt
  # before the exit gets +status+; after the exit, ordinary 503s.
  def mid_life_sse(status)
    lambda do |attempt, rig|
      next :ok_fin if attempt.zero?

      rig.exited? ? 503 : status
    end
  end

  # ------------------------------------------------------------------
  # (a)-(d): entry, probe cadence, state, logging, exit on a secondary 200
  # ------------------------------------------------------------------
  AUTH_STATUSES.each do |status|
    define_method("test_8a_to_d_entry_probe_cadence_and_secondary_exit_#{status}") do
      exit_cycle = 8 # entry on poller cycle 1, probes 2..7 rejected, probe 8 exits
      client = start_client(
        sse_script: mid_life_sse(status),
        fetch_script: lambda do |cycle, leg, _rig|
          next 200 if cycle.zero? # init fetch
          next(leg.zero? ? status : 200) if cycle == exit_cycle
          next 200 if cycle > exit_cycle

          status
        end
      )

      wait_until('auth-failed entry') { @rig.entered? }
      assert client.terminal_failure?, 'terminal_failure? must be true while auth-failed'
      assert_equal :disconnected, client.connection_state
      wait_until('exit INFO') { @rig.exited? }
      wait_until('SSE restarted after exit') do
        ev = @rig.events
        ev[(exit_index(ev) + 1)..].any? { |e| e[0] == :wait && e[1] == :sse }
      end

      ev = @rig.events
      entry = entry_index(ev)
      exit_at = exit_index(ev)
      before = ev[0...entry]
      during = ev[entry...exit_at]
      after = ev[(exit_at + 1)..]

      # (a) before entry: the normal engage rule and SSE ladder, and the cycle
      # that entered is the poller's first.
      assert_equal [120.0], waits(before, :engage), 'mid-life drop: poller engages after 2x interval'
      sse_before = waits(before, :sse)
      # Several real attempts fit in the engage grace; (g) checks the ladder
      # out to the cap.
      assert_operator sse_before.size, :>=, 2, "expected several SSE attempts before entry: #{sse_before}"
      assert_equal SSE_LADDER_AFTER_HEALTHY.first(sse_before.size), sse_before, 'SSE ladder unchanged before entry'
      assert_equal 2, primary_cycles(before), 'init fetch + exactly one poller cycle before entry'

      # (a) after entry: >= 6 probes, each requested in [150s, 300s].
      probes = waits(during, :probe)
      assert_operator probes.size, :>=, 6, "expected >= 6 probes, got #{probes}"
      probes.each { |t| assert_includes(150.0..300.0, t, "probe wait #{t} outside [150s, 300s]") }

      # (b) while auth-failed: no SSE, no poller, one cycle across both legs
      # per probe, disconnected throughout.
      assert_empty ev[entry...exit_at].select { |e| e[0] == :sse }, 'no SSE attempt while auth-failed'
      assert_empty waits(during, :sse)
      assert_empty waits(during, :poll), 'fallback poller must not run while auth-failed'
      assert_empty waits(during, :engage)
      assert_empty logs(during, :warn, /poller engaged/)
      assert_equal probes.size, hits(during, 0).size, 'one primary hit per probe'
      assert_equal probes.size, hits(during, 1).size, 'one secondary hit per probe'
      states = hits(during).map { |h| h[3] }.uniq
      assert_equal [:disconnected], states, 'connection_state must be disconnected (never falling_back) while auth-failed'
      assert_equal [true], hits(during).map { |h| h[4] }.uniq, 'terminal_failure? true while auth-failed'

      # (c) logging from entry through the probes: one ERROR naming the status,
      # nothing else at ERROR or WARN.
      errors = logs(during, :error)
      assert_equal 1, errors.size, "exactly one ERROR from entry: #{errors}"
      assert_match(/#{status}/, errors.first[2])
      assert_match(/primary\.authrig\.test/, errors.first[2], 'ERROR names the host')
      refute_match(/rig-sdk-key-not-real/, errors.first[2], 'ERROR never names the key')
      assert_empty logs(during, :warn), "no WARN while auth-failed: #{logs(during, :warn)}"

      # (d) exit: one INFO, install, SSE restarts from its base backoff.
      assert_equal 1, logs(ev, :info, EXIT).size
      assert_equal 100 + exit_cycle, client.held_generation, 'the secondary-only 200 was installed'
      refute client.terminal_failure?, 'terminal_failure? goes back to false on exit'
      assert_equal SSE_FIRST_FAILURE_WAIT, waits(after, :sse).first, 'SSE restarts from its base backoff'
    end

    define_method("test_8d_exit_on_primary_304_#{status}") do
      client = start_client(
        sse_script: mid_life_sse(status),
        fetch_script: lambda do |cycle, _leg, _rig|
          next 200 if cycle.zero?
          next 304 if cycle >= 3

          status
        end
      )

      wait_until('exit INFO') { @rig.exited? }
      ev = @rig.events
      assert_equal 1, logs(ev, :error, ENTRY).size
      assert_equal 1, logs(ev, :info, EXIT).size
      refute client.terminal_failure?
      wait_until('SSE restarted after 304 exit') do
        e2 = @rig.events
        e2[(exit_index(e2) + 1)..].any? { |e| e[0] == :sse }
      end
    end

    # ----------------------------------------------------------------
    # (e) transient primary rejection: a 200 on any leg never enters
    # ----------------------------------------------------------------
    define_method("test_8e_transient_primary_rejection_with_secondary_200_never_enters_#{status}") do
      client = start_client(
        sse_script: ->(attempt, _rig) { attempt.zero? ? :ok_fin : status },
        fetch_script: lambda do |cycle, leg, _rig|
          next 200 if cycle.zero?

          leg.zero? ? status : 200
        end
      )

      wait_until('three poller cycles') { primary_cycles(@rig.events) >= 4 }
      ev = @rig.events
      refute client.terminal_failure?
      assert_nil entry_index(ev), 'a 200 on any leg must never enter auth-failed'
      assert_empty logs(ev, :error), "no ERROR at all: #{logs(ev, :error)}"
      assert_operator waits(ev, :poll).size, :>=, 2
      assert_equal [60.0], waits(ev, :poll).uniq, 'poller keeps its normal interval'
      sse = waits(ev, :sse)
      assert_equal SSE_LADDER_AFTER_HEALTHY.first(sse.size), sse, 'SSE keeps the normal ladder'
      # R5: a run of SSE auth-class responses logs exactly one WARN (re-armed
      # only by a 200), and never an ERROR.
      assert_equal 1, logs(ev, :warn, /SSE.*#{status}/).size, "SSE #{status} WARN once: #{logs(ev, :warn, /SSE/)}"
      assert_equal :falling_back, client.connection_state
    end

    # ----------------------------------------------------------------
    # (f) mixed legs
    # ----------------------------------------------------------------
    define_method("test_8f_primary_auth_secondary_503_enters_#{status}") do
      start_client(
        sse_script: mid_life_sse(status),
        fetch_script: lambda do |cycle, leg, _rig|
          next 200 if cycle.zero?

          leg.zero? ? status : 503
        end
      )
      wait_until('auth-failed entry') { @rig.entered? }
      wait_until('two probes') { waits(@rig.events, :probe).size >= 2 }
      ev = @rig.events
      assert_equal 1, logs(ev, :error, ENTRY).size
      assert(waits(ev, :probe).all? { |t| (150.0..300.0).cover?(t) })
    end

    define_method("test_8f_primary_auth_secondary_timeout_enters_#{status}") do
      start_client(
        sse_script: mid_life_sse(status),
        fetch_script: lambda do |cycle, leg, _rig|
          next 200 if cycle.zero?

          leg.zero? ? status : :timeout
        end
      )
      wait_until('auth-failed entry') { @rig.entered? }
    end

    define_method("test_8f_primary_503_secondary_auth_does_not_enter_#{status}") do
      client = start_client(
        sse_script: mid_life_sse(status),
        fetch_script: lambda do |cycle, leg, _rig|
          next 200 if cycle.zero?

          leg.zero? ? 503 : status
        end
      )
      wait_until('three poller cycles') { primary_cycles(@rig.events) >= 4 }
      ev = @rig.events
      assert_nil entry_index(ev), 'primary 503 + secondary auth-class must not enter'
      refute client.terminal_failure?
      assert_equal [60.0], waits(ev, :poll).uniq
      assert_empty waits(ev, :probe)
    end

    # ----------------------------------------------------------------
    # repro8: a revoked key on every leg, SSE never connected
    # ----------------------------------------------------------------
    define_method("test_repro8_revoked_key_on_every_leg_enters_after_one_poll_cycle_and_recovers_#{status}") do
      exit_cycle = 8
      client = start_client(
        sse_script: ->(_attempt, rig) { rig.exited? ? :ok_hold : status },
        fetch_script: lambda do |cycle, leg, _rig|
          next(leg.zero? ? status : 200) if cycle == exit_cycle
          next 200 if cycle > exit_cycle

          status
        end
      )

      wait_until('auth-failed entry') { @rig.entered? }
      ev = @rig.events
      assert_equal 2, primary_cycles(ev[0...entry_index(ev)]), 'init fetch + ONE poller cycle, then entry'
      assert client.terminal_failure?
      wait_until('exit INFO') { @rig.exited? }
      wait_until('SSE connected again') { client.connection_state == :connected }

      ev = @rig.events
      during = ev[entry_index(ev)...exit_index(ev)]
      probes = waits(during, :probe)
      assert_equal exit_cycle - 1, probes.size
      probes.each { |t| assert_includes(150.0..300.0, t) }
      # Contract (c) counts ERRORs from entry on; before entry the init call
      # logs its own one ERROR for the rejected key (qfg-9p4i.10, log contract).
      assert_equal 1, logs(during, :error).size, "exactly one ERROR from entry on: #{logs(during, :error)}"
      init_errors = logs(ev[0...entry_index(ev)], :error)
      assert_equal 1, init_errors.size, "one init ERROR before entry: #{init_errors}"
      assert_match(/init FAILED: SDK key rejected \(#{status}\)/, init_errors.first[2])
      refute client.terminal_failure?
      assert_equal 100 + exit_cycle, client.held_generation
    end
  end

  # ------------------------------------------------------------------
  # The qfg-i5xv latch is gone: a transient SSE 401 heals.
  # ------------------------------------------------------------------
  def test_transient_sse_401_then_200_recovers_no_latch
    client = start_client(
      sse_script: ->(attempt, _rig) { attempt.zero? ? 401 : :ok_hold },
      fetch_script: ->(_cycle, _leg, _rig) { 200 }
    )
    wait_until('SSE reconnected after a transient 401') do
      @rig.events.count { |e| e[0] == :sse } >= 2 && client.connection_state == :connected
    end
    refute client.terminal_failure?
    assert_nil entry_index(@rig.events)
  end

  # ------------------------------------------------------------------
  # (g) a non-auth status follows the normal ladder and never enters
  # ------------------------------------------------------------------
  def test_8g_503_everywhere_keeps_normal_ladder_and_never_enters
    client = start_client(
      sse_script: ->(attempt, _rig) { attempt.zero? ? :ok_fin : 503 },
      fetch_script: ->(cycle, _leg, _rig) { cycle.zero? ? 200 : 503 }
    )
    wait_until('three poller cycles and the SSE ladder at its cap') do
      ev = @rig.events
      primary_cycles(ev) >= 4 && waits(ev, :sse).size >= 7
    end
    ev = @rig.events
    assert_nil entry_index(ev)
    refute client.terminal_failure?
    assert_equal SSE_LADDER_AFTER_HEALTHY.first(7), waits(ev, :sse).first(7), 'Test 2 ladder, capped at 30s'
    assert_equal [120.0], waits(ev, :engage)
    assert_equal [60.0], waits(ev, :poll).uniq
    sse = waits(ev, :sse)
    assert_equal SSE_LADDER_AFTER_HEALTHY.first(sse.size), sse
    assert_empty waits(ev, :probe)
    assert_equal :falling_back, client.connection_state
  end

  # ------------------------------------------------------------------
  # Polling mode (enable_sse: false): entry on the first rejected poll, probe
  # wait = max(T, poll interval), exit resumes polling at the interval.
  # ------------------------------------------------------------------
  def test_polling_mode_enters_probes_and_resumes_polling
    exit_cycle = 4
    client = start_client(
      enable_sse: false,
      sse_script: ->(_a, _r) { flunk 'no SSE in polling mode' },
      fetch_script: lambda do |cycle, _leg, _rig|
        next 200 if cycle.zero? || cycle >= exit_cycle

        401
      end
    )
    wait_until('exit INFO') { @rig.exited? }
    wait_until('polling resumed') { primary_cycles(@rig.events) >= exit_cycle + 2 }
    ev = @rig.events
    entry = entry_index(ev)
    exit_at = exit_index(ev)
    assert_equal 2, primary_cycles(ev[0...entry]), 'init + the first poll, then entry'
    probes = waits(ev[entry...exit_at], :probe)
    assert_equal exit_cycle - 1, probes.size
    probes.each { |t| assert_includes(150.0..300.0, t) }
    assert_equal [:disconnected], hits(ev[entry...exit_at]).map { |h| h[3] }.uniq
    after = ev[(exit_at + 1)..]
    assert_equal :wait, after.find { |e| %i[wait hit].include?(e[0]) }[0], 'no immediate fetch after exit'
    assert_equal 60.0, waits(after, :poll).first
    assert_equal :falling_back, client.connection_state
  end

  def test_polling_mode_probe_wait_is_max_of_period_and_poll_interval
    start_client(
      enable_sse: false,
      poll_ms: 400_000,
      sse_script: ->(_a, _r) { flunk 'no SSE in polling mode' },
      fetch_script: ->(cycle, _leg, _rig) { cycle.zero? ? 200 : 403 }
    )
    wait_until('three probes') { waits(@rig.events, :probe).size >= 3 }
    assert_equal [400.0], waits(@rig.events, :probe).uniq
  end
end
