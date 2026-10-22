# frozen_string_literal: true

# Cross-SDK chaos harness — sdk-ruby runner (qfg-47c2.25).
#
# Drives scenarios in ../integration-test-data/chaos/scenarios/ against the
# Ruby SDK via toxiproxy. Mirrors sdk-python/chaos/test_chaos.py,
# sdk-node/chaos/run-chaos.test.ts, and sdk-go/chaos_test.go so the same
# YAML, expression vocabulary, and expectation polling apply per-language.
#
# Run via scripts/run-chaos.sh (which boots toxiproxy + api-delivery first).
#
# Environment knobs:
#   TOXIPROXY_URL           admin API base       (default http://127.0.0.1:8474)
#   CHAOS_SSE_PORT          chaos SSE port       (default 18550)
#   CHAOS_HTTP_PORT         chaos HTTP port      (default 18551)
#   CHAOS_API_DELIVERY_URL  upstream api-delivery URL (set by run-chaos.sh)
#   CHAOS_UPSTREAM_HOST     toxiproxy upstream hostname (default host.docker.internal)
#   CHAOS_ONLY              comma list of scenario numbers to run, e.g. "01,02"
#   CHAOS_SKIP              comma list of scenario numbers to skip
#   CHAOS_POLL_MS           expectation poll interval (default 250)
#
# This file lives OUTSIDE test/ so `bundle exec rake test` does not pick it
# up (Rakefile uses pattern test/**/test_*.rb). Run explicitly via
# `bundle exec ruby -I chaos -I lib chaos/test_chaos.rb`.

require 'net/http'
require 'uri'
require 'json'
require 'yaml'
require 'logger'
require 'minitest/autorun'

require 'quonfig'
require_relative 'scheduler'
require_relative 'expressions'
require_relative 'expectations'
require_relative 'probe'
require_relative 'injection'

# ----- paths -----

CHAOS_HERE       = File.expand_path(__dir__)
CHAOS_SDK_ROOT   = File.expand_path('..', CHAOS_HERE)
CHAOS_REPO_ROOT  = File.expand_path('..', CHAOS_SDK_ROOT)
CHAOS_SCENARIOS  = File.join(CHAOS_REPO_ROOT, 'integration-test-data', 'chaos', 'scenarios')
# 08-auth-failure lives here: it needs HTTP-status injection, which toxiproxy
# cannot do, so it is collected and reported SKIPPED with that reason rather
# than silently never run (qfg-6vno.6).
CHAOS_HTTP_PROXY_SCENARIOS = File.join(CHAOS_REPO_ROOT, 'integration-test-data', 'chaos', 'scenarios-http-proxy')

# ----- env knobs -----

def chaos_env(key, default)
  v = ENV.fetch(key, nil)
  v && !v.empty? ? v : default
end

def chaos_csv(s)
  return [] if s.nil? || s.empty?

  s.split(',').map(&:strip).reject(&:empty?)
end

TOXIPROXY_URL    = chaos_env('TOXIPROXY_URL', 'http://127.0.0.1:8474').freeze
CHAOS_SSE_PORT   = chaos_env('CHAOS_SSE_PORT', '18550').to_i
CHAOS_HTTP_PORT  = chaos_env('CHAOS_HTTP_PORT', '18551').to_i
CHAOS_POLL_MS    = chaos_env('CHAOS_POLL_MS', '250').to_i
CHAOS_ONLY       = chaos_csv(ENV.fetch('CHAOS_ONLY', nil)).freeze
CHAOS_SKIP       = chaos_csv(ENV.fetch('CHAOS_SKIP', nil)).freeze
CHAOS_UPSTREAM   = chaos_env('CHAOS_UPSTREAM_HOST', 'host.docker.internal').freeze

# ----- toxiproxy admin client -----

class Toxiproxy
  def initialize(base)
    @base = base.sub(%r{/+\z}, '')
  end

  def ping
    resp = get('/version')
    resp.is_a?(Net::HTTPSuccess)
  rescue StandardError
    false
  end

  def upsert_proxy(name, listen, upstream)
    delete("/proxies/#{name}")
    body = JSON.generate(
      name: name, listen: listen, upstream: upstream, enabled: true
    )
    resp = post('/proxies', body)
    return if resp.is_a?(Net::HTTPSuccess)

    raise "upsert_proxy #{name}: #{resp.code} #{resp.body}"
  end

  def clear_toxics(proxy)
    resp = get("/proxies/#{proxy}/toxics")
    return unless resp.is_a?(Net::HTTPSuccess)

    list = begin
      JSON.parse(resp.body)
    rescue StandardError
      []
    end
    list.each do |t|
      delete("/proxies/#{proxy}/toxics/#{t['name']}")
    end
  rescue StandardError
    # best-effort cleanup
  end

  def set_enabled(proxy, enabled)
    body = JSON.generate(enabled: enabled)
    resp = post("/proxies/#{proxy}", body)
    return if resp.is_a?(Net::HTTPSuccess)

    raise "set_enabled #{proxy}: #{resp.code} #{resp.body}"
  end

  def add_toxic(proxy, name, type, stream, attributes)
    body = JSON.generate(
      name: name,
      type: type,
      stream: (stream && !stream.empty? ? stream : 'downstream'),
      attributes: attributes || {}
    )
    resp = post("/proxies/#{proxy}/toxics", body)
    return if resp.is_a?(Net::HTTPSuccess)

    raise "add_toxic #{proxy}/#{name}: #{resp.code} #{resp.body}"
  end

  def remove_toxic(proxy, name)
    delete("/proxies/#{proxy}/toxics/#{name}")
  rescue StandardError
    # best-effort
  end

  private

  def http_for(path)
    uri = URI.parse("#{@base}#{path}")
    [uri, Net::HTTP.new(uri.host, uri.port).tap do |h|
      h.open_timeout = 5
      h.read_timeout = 5
    end]
  end

  def get(path)
    uri, http = http_for(path)
    http.request(Net::HTTP::Get.new(uri.request_uri))
  end

  def post(path, body)
    uri, http = http_for(path)
    req = Net::HTTP::Post.new(uri.request_uri)
    req['Content-Type'] = 'application/json'
    req.body = body
    http.request(req)
  end

  def delete(path)
    uri, http = http_for(path)
    http.request(Net::HTTP::Delete.new(uri.request_uri))
  rescue StandardError
    nil
  end
end

# Duck-typed logger that pipes every Quonfig::InternalLogger write into the
# probe. InternalLogger.user_logger redirects all `log_message` calls here
# (see lib/quonfig/internal_logger.rb).
class ChaosLoggerTap
  %i[trace debug info warn error fatal].each do |lvl|
    define_method(lvl) do |msg|
      @probe&.log(lvl, msg.to_s)
    end
  end

  def initialize(probe)
    @probe = probe
  end

  def respond_to_missing?(_, _ = false) = true
end

# ----- skipped-expression tally -----

# Every expectation (or compound leaf) the rig cannot evaluate is reported as
# SKIPPED with its reason, per expectation and again in one run-end tally, so a
# skip is never mistaken for a pass (qfg-goi1.1.3, Decision 6).
module ChaosSkipTally
  @lock = Mutex.new
  @entries = []

  class << self
    def record(scenario, idx, leaf)
      @lock.synchronize { @entries << [scenario, idx, leaf] }
    end

    def report(io = $stdout)
      entries = @lock.synchronize { @entries.dup }
      return if entries.empty?

      io.puts
      io.puts "chaos: #{entries.size} skipped expression(s) — not evaluated, NOT counted as passes:"
      entries.each { |scenario, idx, leaf| io.puts "  SKIPPED  #{scenario} exp[#{idx}]: #{leaf}" }
    end
  end
end

Minitest.after_run { ChaosSkipTally.report }

# ----- scenario runner -----

# Expectations sdk-ruby cannot honestly evaluate, keyed by scenario number and
# the exact assert text. Each is reported SKIPPED with its reason (Decision 6),
# never passed off probe bookkeeping (qfg-6vno.6).
CHAOS_KNOWN_SKIPS = {
  ['10', "client.sdkMetric('quonfig_sdk_worker_restart_total', layer='1') >= 1"] =>
    'sdk-ruby recovers an onConfigUpdate raise inline (Client#notify_on_update_callback) and does not ' \
    'count it in worker_restart_total; supervisor contract Test 5 allows either. 10 exp[3] (the ERROR ' \
    'log) and exp[2] (worker alive) carry the coverage. Whether ruby should count it like sdk-go ' \
    '(reason=callback_panic) is open: qfg-6vno.6.1'
}.freeze

# Whole tests sdk-ruby cannot run, decided by shape before the run.
def chaos_test_skip_reason(scenario_num, run)
  setup = run['setup'] || {}
  if setup['catch_init_failure'] && setup['on_init_failure'].to_s == 'fail'
    return 'sdk-ruby on_init_failure: :fail raises from Client.new and returns no client object ' \
           '(init-failure design, Decisions 4), so there is no caught client to watch heal'
  end
  reason = chaos_unsupported_step_reason(run['chaos'])
  return "#{scenario_num}: #{reason}" if reason

  nil
end

CHAOS_INIT_FAILURE_MODES = %w[fail wait continue].freeze

# Build the Quonfig::Client configured to talk through the chaos ports.
# setup.on_init_failure / setup.init_timeout_ms (00-*) override the default
# init behavior; without them the client continues on defaults after 15s.
def chaos_build_client(setup)
  mode = setup['on_init_failure']
  init_timeout_ms = mode ? setup['init_timeout_ms'].to_i : 15_000
  options = Quonfig::Options.new(
    sdk_key: 'test-backend-key',
    api_urls: ["http://127.0.0.1:#{CHAOS_HTTP_PORT}"],
    enable_sse: true,
    enable_polling: true,
    poll_interval: 60,
    init_timeout_ms: init_timeout_ms,
    on_init_failure: mode ? mode.to_sym : Quonfig::Options::ON_INITIALIZATION_FAILURE::CONTINUE,
    on_no_default: Quonfig::Options::ON_NO_DEFAULT::RETURN_NIL,
    context_upload_mode: :none,
    collect_evaluation_summaries: false
  )
  # Override sse_api_urls to point at the chaos SSE port (Options.init
  # auto-derives sse_api_urls from api_urls by prepending `stream.`; for the
  # chaos harness we route the two ports independently).
  options.instance_variable_set(
    :@sse_api_urls,
    ["http://127.0.0.1:#{CHAOS_SSE_PORT}"]
  )

  Quonfig::Client.new(options)
end

# Hand a constructed client to the probe and register the one on_update
# callback: it counts the SDK's ready/update events (readyEventCount) and, in
# user_callback: throw mode, then raises (scenario 10).
def chaos_attach_client(probe, client, user_callback_mode)
  client.on_update do
    probe.note_ready_event
    raise 'simulated user-callback throw for chaos scenario 10' if user_callback_mode == 'throw'
  end
  probe.client = client
end

# Stop-event lives in chaos/scheduler.rb so the cancellation behavior can be
# unit-tested without booting toxiproxy (qfg-p35y).
ChaosStopFlag = Quonfig::Chaos::StopFlag

def chaos_now_ms
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
end

# Apply one chaos step. A step that cannot be applied (unknown shape, a clear
# naming no injection, a toxiproxy error) is recorded in +errors+ and fails
# the scenario: the fault did not happen, so nothing after it is evidence.
def chaos_fire_event(tp, ev, injection_states, errors)
  at = (ev['at_ms'] || 0).to_i
  if ev['inject']
    st = chaos_apply_inject(tp, ev['inject'])
    injection_states[ev['inject']['name']] = st if ev['inject']['name']
    puts "[#{at}ms] inject #{ev['inject'].inspect}"
  elsif ev['clear']
    raise ChaosUnsupportedStep, "clear: no injection named #{ev['clear'].inspect}" unless injection_states.key?(ev['clear'])

    chaos_clear_inject(tp, injection_states[ev['clear']])
    injection_states.delete(ev['clear'])
    puts "[#{at}ms] clear #{ev['clear']}"
  elsif ev['process']
    chaos_apply_process(tp, ev['process'])
    puts "[#{at}ms] process #{ev['process'].inspect}"
  else
    raise ChaosUnsupportedStep, "unknown chaos step #{ev.inspect}"
  end
rescue StandardError => e
  msg = "[#{at}ms] chaos event failed: #{e.class}: #{e.message}"
  puts msg
  errors << msg
end

def chaos_run_scenario(tp, run, scenario_num)
  tp.clear_toxics('sse')
  tp.clear_toxics('http')
  tp.set_enabled('sse', true)
  tp.set_enabled('http', true)

  probe = ChaosProbe.new
  setup = run['setup'] || {}
  user_callback_mode = setup['user_callback']
  wall_clock_ms = ((setup['wall_clock_seconds'] || 30).to_f * 1000).to_i
  init_mode = setup['on_init_failure']
  raise ChaosUnsupportedStep, "setup.on_init_failure #{init_mode.inspect} (expected #{CHAOS_INIT_FAILURE_MODES.join('|')})" if init_mode && !CHAOS_INIT_FAILURE_MODES.include?(init_mode.to_s)

  # Hook the internal logger so every quonfig log line lands in the probe.
  prev_user_logger = Quonfig::InternalLogger.user_logger
  Quonfig::InternalLogger.user_logger = ChaosLoggerTap.new(probe)

  client = nil
  init_thread = nil
  stop_flag = ChaosStopFlag.new
  injection_states = {}
  event_errors = []
  scheduled_threads = []

  begin
    # t=0 (README "Timeline rules", rule 2; qfg-goi1.10.35): Client.new fetches
    # inline, so the baseline and the chaos event threads start BEFORE it and
    # the initial fetch counts against every within_ms. Pre-init events
    # (at_ms <= 0) are applied synchronously so they are in place before the
    # first fetch.
    baseline_ms = chaos_now_ms
    events = run['chaos'] || []
    pre_init, scheduled = events.partition { |ev| (ev['at_ms'] || 0).to_i <= 0 }
    pre_init.each { |ev| chaos_fire_event(tp, ev, injection_states, event_errors) }

    # Schedule chaos events. The scheduler uses stop_flag.wait under the
    # hood so the ensure block's `stop_flag.set!` cancels any pending event
    # — without that, a deferred "clear" from a scenario that ended early
    # would fire DURING the next scenario and corrupt its toxiproxy state
    # (qfg-p35y: scenario 07's clear half_open leaked into scenario 05,
    # re-enabling SSE 16s into the 180s outage and preventing falling_back
    # from engaging).
    scheduled.each do |ev|
      delay = [(ev['at_ms'] || 0).to_i - (chaos_now_ms - baseline_ms), 0].max
      scheduled_threads << Quonfig::Chaos.schedule_event(stop_flag, delay) do
        chaos_fire_event(tp, ev, injection_states, event_errors)
      end
    end

    if init_mode
      # Init-failure scenarios (00-*): the init call runs on its own thread so
      # the tick loop keeps evaluating while it blocks; initState() reports
      # pending until Client.new returns or raises.
      probe.init_state = 'pending'
      init_thread = Thread.new do
        Thread.current.report_on_exception = false
        c = chaos_build_client(setup)
        client = c
        chaos_attach_client(probe, c, user_callback_mode)
        probe.init_state = 'returned'
      rescue StandardError => e
        probe.log(:error, "chaos runner: init raised: #{e.class}: #{e.message}")
        probe.init_state = 'raised'
      end
    else
      begin
        client = chaos_build_client(setup)
        chaos_attach_client(probe, client, user_callback_mode)
      rescue StandardError => e
        probe.process_crashed = true
        probe.log(:error, "init failed: #{e.class}: #{e.message}")
      end
    end

    states = (run['expectations'] || []).each_with_index.map do |e, i|
      known_skip = CHAOS_KNOWN_SKIPS[[scenario_num, e['assert']]]
      st = Quonfig::Chaos::Expectations.new_state(
        i, e, skip_only: known_skip || Quonfig::Chaos::Expressions.skip_only?(e['assert'])
      )
      st[:known_skip] = known_skip
      st
    end

    poll_interval = CHAOS_POLL_MS / 1000.0

    loop do
      elapsed = chaos_now_ms - baseline_ms
      break if elapsed >= wall_clock_ms

      states.each do |s|
        Quonfig::Chaos::Expectations.step(s, elapsed, chaos_now_ms) do
          next [:skip, "SKIPPED #{s[:known_skip]}", [s[:known_skip]]] if s[:known_skip]

          result = Quonfig::Chaos::Expressions.evaluate(s[:exp]['assert'], probe)
          [result.status, result.reason, result.skipped]
        end
      end
      break if states.all? { |s| Quonfig::Chaos::Expectations.terminal?(s) }

      sleep poll_interval
    end

    states.each { |s| s[:failed] = true unless s[:passed] || s[:skipped] }

    details = []
    passed = 0
    failed = 0
    skipped = 0
    states.each do |s|
      (s[:skipped_leaves] || []).each { |leaf| ChaosSkipTally.record(run['name'], s[:idx], leaf) }
      if s[:skipped]
        skipped += 1
      elsif s[:passed]
        passed += 1
      else
        failed += 1
      end
      details << Quonfig::Chaos::Expectations.describe(s)
    end
    event_errors.each do |msg|
      failed += 1
      details << "FAIL  chaos step not applied, scenario is not evidence: #{msg}"
    end
    snap = probe.snapshot
    details << "summary: #{passed} passed, #{failed} failed, #{skipped} skipped " \
               "(state=#{snap[:conn_state]}, restartLayer1=#{snap[:restart_layer1].inspect}, " \
               "restartLayer2=#{snap[:restart_layer2].inspect}, fallback=#{snap[:fallback_active]}, " \
               "lastRefreshMs=#{snap[:last_refresh_ms]}, initState=#{probe.init_state}, " \
               "readyEvents=#{probe.ready_event_count})"

    [passed, failed, details]
  ensure
    stop_flag.set!
    scheduled_threads.each do |t|
      t.join(1.0)
    rescue StandardError
      nil
    end
    # A wait-mode init still blocked at wall-clock end is torn down with the
    # scenario; the expectations already recorded the outcome.
    if init_thread&.alive?
      init_thread.kill
      init_thread.join(2.0)
    end
    begin
      client&.stop
    rescue StandardError
      # ignore
    end
    Quonfig::InternalLogger.user_logger = prev_user_logger
  end
end

# ----- collection -----

def chaos_scenario_files
  [CHAOS_SCENARIOS, CHAOS_HTTP_PROXY_SCENARIOS].flat_map do |dir|
    Dir.exist?(dir) ? Dir.glob(File.join(dir, '*.yaml')) : []
  end
end

def chaos_scenario_number(path)
  name = File.basename(path)
  idx = name.index('-')
  idx ? name[0...idx] : name
end

def chaos_slug(name)
  name.to_s.downcase
      .gsub(/[^a-z0-9]+/, '_')
      .gsub(/\A_+|_+\z/, '')
      .slice(0, 60)
end

def chaos_load_runs
  out = []
  chaos_scenario_files.each do |f|
    num = chaos_scenario_number(f)
    next if !CHAOS_ONLY.empty? && !CHAOS_ONLY.include?(num)
    next if CHAOS_SKIP.include?(num)

    begin
      doc = Quonfig::Chaos::Expectations.load_scenario_file(f)
    rescue Psych::Exception => e
      warn "chaos: failed to parse #{f}: #{e.class}: #{e.message}"
      next
    end
    # An unknown expectation key (Quonfig::Chaos::Expectations::UnknownKeyError)
    # propagates and fails the run, naming the key (README rule 4).
    (doc['tests'] || []).each do |run|
      out << [f, run]
    end
  end
  out
end

# Single shared toxiproxy + setup, lazy-built per process.
module ChaosShared
  @lock = Mutex.new
  @toxiproxy = nil
  @setup_error = nil
  @setup_done = false

  class << self
    def toxiproxy
      ensure_setup
      @toxiproxy
    end

    def setup_error
      ensure_setup
      @setup_error
    end

    private

    def ensure_setup
      @lock.synchronize do
        return if @setup_done

        @setup_done = true
        api_url = ENV.fetch('CHAOS_API_DELIVERY_URL', nil)
        if api_url.nil? || api_url.empty?
          @setup_error = 'CHAOS_API_DELIVERY_URL not set — run scripts/run-chaos.sh to boot the harness'
          return
        end
        tp = Toxiproxy.new(TOXIPROXY_URL)
        unless tp.ping
          @setup_error = "toxiproxy not reachable at #{TOXIPROXY_URL} — run scripts/run-chaos.sh first"
          return
        end
        uri = URI.parse(api_url)
        upstream_port = uri.port || 6550
        begin
          tp.upsert_proxy('sse',  "0.0.0.0:#{CHAOS_SSE_PORT}",  "#{CHAOS_UPSTREAM}:#{upstream_port}")
          tp.upsert_proxy('http', "0.0.0.0:#{CHAOS_HTTP_PORT}", "#{CHAOS_UPSTREAM}:#{upstream_port}")
        rescue StandardError => e
          @setup_error = "toxiproxy proxy setup failed: #{e.message}"
          return
        end
        @toxiproxy = tp
      end
    end
  end
end

# ----- generate Minitest methods -----

class ChaosTest < Minitest::Test
  # generated at load time; one method per scenario test entry
end

runs = chaos_load_runs

runs.each do |scenario_path, run|
  num    = chaos_scenario_number(scenario_path)
  slug   = chaos_slug(run['name'] || File.basename(scenario_path, '.yaml'))
  method = "test_chaos_#{num}_#{slug}"
  base   = method
  i = 2
  while ChaosTest.method_defined?(method)
    method = "#{base}_#{i}"
    i += 1
  end

  ChaosTest.send(:define_method, method) do
    reason = chaos_test_skip_reason(num, run)
    if reason
      ChaosSkipTally.record(run['name'], '*', reason)
      skip "SKIPPED #{reason}"
    end
    skip ChaosShared.setup_error if ChaosShared.setup_error

    tp = ChaosShared.toxiproxy
    passed, failed, details = chaos_run_scenario(tp, run, num)
    details.each { |line| puts line }
    assert_equal 0, failed, "#{failed} expectation(s) failed in #{run['name']}"
    assert passed >= 0
  end
end

# Print the generated method names when the runner is loaded with no
# CHAOS_API_DELIVERY_URL — useful for sanity-checking parsing without docker.
if ENV['CHAOS_LIST_TESTS'] == '1'
  ChaosTest.instance_methods(false).sort.each { |m| puts m }
  exit 0
end
