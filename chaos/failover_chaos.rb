# frozen_string_literal: true

# Failover + canonical-ordering chaos runner — sdk-ruby (qfg-7h5d.1.9).
#
# Mirrors sdk-go's failover_chaos_test.go. Consumes the two shared corpus rigs
# from ../integration-test-data/chaos/:
#
#   scenarios-failover/ (f01-f05) — ONE fixture upstream behind TWO proxies
#     (primary 'http' leg + 'secondary' leg). Faults hit the primary leg only;
#     the SDK must fail the HTTP config fetch over to the secondary and keep
#     serving, fast (well inside init_timeout_ms). SSE is asserted NOT to repoint.
#
#   scenarios-ordering/ (o01-o04) — TWO fixture upstreams pinned to divergent
#     Meta.generations. The SDK must end up holding the higher generation and an
#     established client must never regress to an older one. A fallback poller
#     models ongoing config refresh so the reject-older guard is exercised on the
#     failover/poll install path.
#
# Only toxiproxy needs to be booted (scripts/run-failover-chaos.sh does that via
# the shared launcher). THIS runner builds nothing: the wrapper passes the
# already-built api-delivery binary; the runner spawns its own fixture
# upstream(s) and repoints the seeded 'http'/'secondary'/'sse' proxies at them,
# pinning a generation per ordering scenario via FIXTURE_GENERATION.
#
# Lives OUTSIDE test/ so `rake test` does not pick it up. Run explicitly via
# scripts/run-failover-chaos.sh (or, with toxiproxy + the env knobs set, via
# `bundle exec ruby -I chaos -I lib chaos/failover_chaos.rb`).
#
# Env knobs:
#   TOXIPROXY_URL              admin API base            (default http://127.0.0.1:8474)
#   CHAOS_API_DELIVERY_BIN     path to built api-delivery binary (required)
#   CHAOS_FIXTURE_DIR          FIXTURE_DIR for the upstream(s)   (required)
#   CHAOS_SDK_KEYS_FILE        SDK_KEYS_FILE for the upstream(s) (required)
#   CHAOS_UPSTREAM_HOST        host toxiproxy forwards to  (default host.docker.internal)
#   CHAOS_RUN                  only run scenario files whose basename matches this regex
#   CHAOS_SKIP                 skip scenario files whose basename matches this regex
#                              (the CI default skips o01-secondary-newer — cross-leg
#                              max-wins, qfg-7h5d.1.14, out of the §5f reject-older scope)
#   CHAOS_POLL_MS              expectation poll interval  (default 200)

require 'net/http'
require 'uri'
require 'json'
require 'yaml'
require 'socket'
require 'minitest/autorun'

require 'quonfig'
require_relative 'scheduler'

# ----- paths -----

FAILOVER_HERE      = File.expand_path(__dir__)
FAILOVER_SDK_ROOT  = File.expand_path('..', FAILOVER_HERE)
FAILOVER_REPO_ROOT = File.expand_path('..', FAILOVER_SDK_ROOT)
FAILOVER_CHAOS_DIR = File.join(FAILOVER_REPO_ROOT, 'integration-test-data', 'chaos')
FAILOVER_SCEN_DIR  = File.join(FAILOVER_CHAOS_DIR, 'scenarios-failover')
ORDERING_SCEN_DIR  = File.join(FAILOVER_CHAOS_DIR, 'scenarios-ordering')

# Rig host ports the launcher publishes (docker-compose.yml): the SDK targets
# [primary 18551, secondary 18552]; SSE rides the primary leg via 18550.
RIG_SSE_PORT       = 18_550
RIG_PRIMARY_PORT   = 18_551
RIG_SECONDARY_PORT = 18_552

def failover_env(key, default)
  v = ENV.fetch(key, nil)
  v && !v.empty? ? v : default
end

TOXIPROXY_URL       = failover_env('TOXIPROXY_URL', 'http://127.0.0.1:8474').freeze
CHAOS_UPSTREAM_HOST = failover_env('CHAOS_UPSTREAM_HOST', 'host.docker.internal').freeze
FAILOVER_POLL_MS    = failover_env('CHAOS_POLL_MS', '200').to_i
FAILOVER_RUN_RE     = (v = ENV.fetch('CHAOS_RUN', nil)) && !v.empty? ? Regexp.new(v) : nil
FAILOVER_SKIP_RE    = (v = ENV.fetch('CHAOS_SKIP', nil)) && !v.empty? ? Regexp.new(v) : nil

# ----- toxiproxy admin client -----

class FailoverToxiproxy
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
    body = JSON.generate(name: name, listen: listen, upstream: upstream, enabled: true)
    resp = post('/proxies', body)
    return if resp.is_a?(Net::HTTPSuccess)

    raise "upsert_proxy #{name}: #{resp.code} #{resp.body}"
  end

  def set_enabled(proxy, enabled)
    resp = post("/proxies/#{proxy}", JSON.generate(enabled: enabled))
    return if resp.is_a?(Net::HTTPSuccess)

    raise "set_enabled #{proxy}: #{resp.code} #{resp.body}"
  end

  def add_toxic(proxy, name, type, stream, attributes)
    body = JSON.generate(
      name: name, type: type,
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
    nil
  end

  def clear_toxics(proxy)
    resp = get("/proxies/#{proxy}/toxics")
    return unless resp.is_a?(Net::HTTPSuccess)

    list = begin
      JSON.parse(resp.body)
    rescue StandardError
      []
    end
    list.each { |t| delete("/proxies/#{proxy}/toxics/#{t['name']}") }
  rescue StandardError
    nil
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

# ----- upstream spawning -----

# Spawns fixture-mode api-delivery instances, pinned to a chosen Meta.generation,
# and tears them down. Mirrors sdk-go's spawnChaosUpstream.
module FailoverUpstreams
  @pids = []

  class << self
    attr_reader :pids

    def free_port
      server = TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]
      server.close
      port
    end

    def spawn(generation)
      bin = ENV.fetch('CHAOS_API_DELIVERY_BIN')
      port = free_port
      env = {
        'PORT' => port.to_s,
        'FIXTURE_DIR' => ENV.fetch('CHAOS_FIXTURE_DIR'),
        'SDK_KEYS_FILE' => ENV.fetch('CHAOS_SDK_KEYS_FILE'),
        'QUONFIG_ENVIRONMENT' => 'development',
        'SSE_HEARTBEAT_INTERVAL' => '1s',
        'FIXTURE_GENERATION' => generation.to_s
      }
      pid = Process.spawn(env, bin, out: $stderr, err: $stderr)
      @pids << pid
      wait_for_listen(port)
      [pid, port]
    end

    def kill(pid)
      return if pid.nil?

      Process.kill('KILL', pid)
      Process.wait(pid)
    rescue StandardError
      nil
    ensure
      @pids.delete(pid)
    end

    def wait_for_listen(port)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        return if tcp_open?(port)

        sleep 0.05
      end
      raise "api-delivery did not start on :#{port} within 15s"
    end

    def tcp_open?(port)
      TCPSocket.new('127.0.0.1', port).tap(&:close)
      true
    rescue StandardError
      false
    end
  end
end

at_exit { FailoverUpstreams.pids.dup.each { |pid| FailoverUpstreams.kill(pid) } }

# ----- SDK probe -----

# Thin read-only view over the diagnostic accessors the SDK exposes for this
# epic (qfg-7h5d.1.9). nil-safe before the client is constructed.
class FailoverProbe
  def initialize
    @lock = Mutex.new
    @client = nil
  end

  def client=(c)
    @lock.synchronize { @client = c }
  end

  def client
    @lock.synchronize { @client }
  end

  def ready
    c = client
    c ? c.ready? : false
  end

  def resolved_from
    c = client
    c ? c.resolved_from : ''
  end

  def held_generation
    c = client
    c ? c.held_generation : 0
  end

  def install_count
    c = client
    c ? c.config_install_count : 0
  end

  def sse_failed_over
    c = client
    c ? c.sse_failed_over_to_secondary? : false
  end
end

# ----- expression evaluator -----

RE_READY        = /\Aclient\.ready\(\)\s*==\s*(true|false)\z/
RE_RESOLVED     = /\Aclient\.resolvedFrom\(\)\s*(==|!=)\s*'([^']+)'\z/
RE_HELD_GEN      = /\Aclient\.heldGeneration\(\)\s*(>=|<=|==|!=|<|>)\s*(-?\d+)\z/
RE_INSTALL_CNT   = /\Aclient\.configInstallCount\(\)\s*(>=|<=|==|!=|<|>)\s*(-?\d+)\z/
RE_SSE_FAILOVER  = /\Aclient\.sseFailedOverToSecondary\(\)\s*==\s*(true|false)\z/

def failover_compare(op, a, b)
  case op
  when '==' then a == b
  when '!=' then a != b
  when '<'  then a < b
  when '<=' then a <= b
  when '>'  then a > b
  when '>=' then a >= b
  else false
  end
end

def failover_eval_leaf(expr, probe)
  expr = expr.strip
  if (m = RE_READY.match(expr))
    want = m[1] == 'true'
    got = probe.ready
    return [got == want, "ready=#{got} want #{want}"]
  end
  if (m = RE_RESOLVED.match(expr))
    got = probe.resolved_from
    want = m[2]
    ok = m[1] == '==' ? got == want : got != want
    return [ok, "resolvedFrom=#{got.inspect} #{m[1]} #{want.inspect}"]
  end
  if (m = RE_HELD_GEN.match(expr))
    got = probe.held_generation
    want = m[2].to_i
    return [failover_compare(m[1], got, want), "heldGeneration=#{got} #{m[1]} #{want}"]
  end
  if (m = RE_INSTALL_CNT.match(expr))
    got = probe.install_count
    want = m[2].to_i
    return [failover_compare(m[1], got, want), "configInstallCount=#{got} #{m[1]} #{want}"]
  end
  if (m = RE_SSE_FAILOVER.match(expr))
    want = m[1] == 'true'
    got = probe.sse_failed_over
    return [got == want, "sseFailedOverToSecondary=#{got} want #{want}"]
  end
  [false, "unrecognized expression: #{expr}"]
end

def failover_evaluate(expr, probe)
  expr = expr.to_s.strip
  return [true, ''] if expr.empty?

  if expr.include?(' OR ')
    reasons = []
    expr.split(' OR ').each do |p|
      ok, why = failover_evaluate(p, probe)
      return [true, ''] if ok

      reasons << why
    end
    return [false, "OR: #{reasons.join(' | ')}"]
  end
  if expr.include?(' AND ')
    expr.split(' AND ').each do |p|
      ok, why = failover_evaluate(p, probe)
      return [false, "AND: #{why}"] unless ok
    end
    return [true, '']
  end
  failover_eval_leaf(expr, probe)
end

# ----- chaos injection (failover-rig aliases, fault the PRIMARY leg) -----

ChaosStopFlag = Quonfig::Chaos::StopFlag

# Apply one inject alias against the primary 'http' (or 'sse') leg. Each alias
# carries its own duration in ms after which the fault auto-clears, so the rig
# needs no explicit `clear` event (mirrors sdk-go's applyFailoverInject). The
# self-restore is scheduled on a stop_flag-cancellable thread.
def failover_apply_inject(tp, inj, threads, stop_flag)
  name = inj['name'] || 'primary_fault'
  if (ms = inj['primary_refused_ms'])
    tp.set_enabled('http', false)
    threads << failover_restore_after(stop_flag, ms) { tp.set_enabled('http', true) }
  elsif (ms = inj['primary_hang_ms'])
    tp.add_toxic('http', name, 'timeout', 'downstream', { 'timeout' => ms })
    threads << failover_restore_after(stop_flag, ms) { tp.remove_toxic('http', name) }
  elsif (ms = inj['primary_latency_ms'])
    tp.add_toxic('http', name, 'latency', 'downstream', { 'latency' => ms })
    threads << failover_restore_after(stop_flag, ms) { tp.remove_toxic('http', name) }
  elsif (ms = inj['sse_down_ms'])
    tp.set_enabled('sse', false)
    threads << failover_restore_after(stop_flag, ms) { tp.set_enabled('sse', true) }
  else
    puts "failover inject: unhandled shape #{inj.inspect} — no-op"
  end
end

def failover_restore_after(stop_flag, ms, &block)
  Thread.new do
    stop_flag.wait(ms / 1000.0)
    block.call
  rescue StandardError => e
    puts "failover restore failed: #{e.class}: #{e.message}"
  end
end

# ----- scenario runner -----

def failover_build_client(probe, sse_enabled, polling)
  primary   = "http://127.0.0.1:#{RIG_PRIMARY_PORT}"
  secondary = "http://127.0.0.1:#{RIG_SECONDARY_PORT}"
  stream    = "http://127.0.0.1:#{RIG_SSE_PORT}"

  options = Quonfig::Options.new(
    sdk_key: 'test-backend-key',
    api_urls: [primary, secondary],
    enable_sse: sse_enabled,
    fallback_poll_enabled: polling,
    fallback_poll_interval_ms: 750,
    init_timeout_ms: 8000,
    # ~2s per-URL bound: short enough that a hung/slow primary fails over inside
    # the 4s within_ms budget; the §5g fix under test.
    config_fetch_timeout_ms: 2000,
    on_init_failure: Quonfig::Options::ON_INITIALIZATION_FAILURE::RETURN,
    on_no_default: Quonfig::Options::ON_NO_DEFAULT::RETURN_NIL,
    context_upload_mode: :none,
    collect_evaluation_summaries: false
  )
  # SSE rides a SINGLE leg (the primary 'sse' proxy). The failover epic asserts
  # SSE does NOT repoint to the secondary — giving it one URL makes that
  # structural (and #sse_failed_over_to_secondary? observable if it ever did).
  options.instance_variable_set(:@sse_api_urls, [stream])

  client = Quonfig::Client.new(options)
  probe.client = client
  client
end

def failover_run_scenario(tp, run, ordering:)
  # Clean proxy state — no leftover toxics, all legs enabled.
  %w[http secondary sse].each do |p|
    tp.clear_toxics(p)
    tp.set_enabled(p, true)
  end

  probe = FailoverProbe.new
  setup = run['setup'] || {}
  sse_enabled = setup['sse_endpoint'] && setup['sse_endpoint'] != 'disabled'
  wall_clock_ms = ((setup['wall_clock_seconds'] || 30).to_f * 1000).to_i

  stop_flag = ChaosStopFlag.new
  threads = []
  client = nil

  begin
    events = run['chaos'] || []
    # Injects at at_ms <= 0 must be in place BEFORE the synchronous initial
    # fetch so the fault is observed at init (Ruby's Client.new fetches inline).
    # Injects at at_ms > 0 fire after the client is up, relative to baseline.
    pre_init, scheduled = events.partition { |ev| ev['inject'] && (ev['at_ms'] || 0).to_i <= 0 }

    pre_init.each do |ev|
      failover_apply_inject(tp, ev['inject'], threads, stop_flag)
      puts "[pre-init] inject #{ev['inject'].inspect}"
    end

    begin
      # Ordering rig: drive ongoing refresh via the fallback poller so the
      # reject-older guard is exercised on the poll/failover install path.
      # Failover rig: initial fetch is enough; leave polling off so install
      # accounting stays deterministic.
      client = failover_build_client(probe, sse_enabled, ordering)
    rescue StandardError => e
      puts "client init raised: #{e.class}: #{e.message}"
    end

    baseline_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i

    scheduled.each do |ev|
      at = (ev['at_ms'] || 0).to_i
      threads << Quonfig::Chaos.schedule_event(stop_flag, at) do
        failover_apply_inject(tp, ev['inject'], threads, stop_flag)
        puts "[#{at}ms] inject #{ev['inject'].inspect}"
      rescue StandardError => e
        puts "[#{at}ms] chaos event failed: #{e.class}: #{e.message}"
      end
    end

    states = (run['expectations'] || []).each_with_index.map do |e, i|
      { idx: i, exp: e, passed: false, failed: false, held_since: nil, hit_at: nil, last_reason: '' }
    end

    poll_interval = FAILOVER_POLL_MS / 1000.0
    loop do
      elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i - baseline_ms
      break if elapsed >= wall_clock_ms

      all_terminal = true
      states.each do |s|
        next if s[:passed] || s[:failed]

        ok, why = failover_evaluate(s[:exp]['assert'], probe)
        s[:last_reason] = why
        now_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
        if ok
          if s[:held_since].nil?
            s[:held_since] = now_ms
            s[:hit_at] = elapsed
          end
          hold_for = (s[:exp]['must_hold_for_ms'] || 0).to_i
          s[:passed] = true if hold_for <= 0 || (now_ms - s[:held_since]) >= hold_for
        else
          s[:held_since] = nil
        end
        s[:failed] = true if !s[:passed] && elapsed > s[:exp]['within_ms'].to_i
        all_terminal = false unless s[:passed] || s[:failed]
      end
      break if all_terminal

      sleep poll_interval
    end

    states.each { |s| s[:failed] = true unless s[:passed] }

    passed = 0
    failed = 0
    details = []
    states.each do |s|
      exp = s[:exp]
      label = "exp[#{s[:idx]}] within=#{exp['within_ms']}ms hold=#{exp['must_hold_for_ms'] || 0}ms: #{exp['assert']}"
      if s[:passed]
        passed += 1
        details << "PASS  #{label} (hit at #{s[:hit_at]}ms)"
      else
        failed += 1
        details << "FAIL  #{label} — last: #{s[:last_reason]}"
      end
    end
    details << "summary: #{passed} passed, #{failed} failed " \
               "(ready=#{probe.ready}, resolvedFrom=#{probe.resolved_from.inspect}, " \
               "heldGeneration=#{probe.held_generation}, installCount=#{probe.install_count}, " \
               "sseFailedOver=#{probe.sse_failed_over})"

    [passed, failed, details]
  ensure
    stop_flag.set!
    threads.each do |t|
      t.join(2.0)
    rescue StandardError
      nil
    end
    begin
      client&.stop
    rescue StandardError
      nil
    end
  end
end

# ----- proxy reconfiguration -----

def failover_reconfigure_proxies(tp, primary_port, secondary_port)
  # SSE always tracks the primary upstream (failover is HTTP-only).
  tp.upsert_proxy('http', "0.0.0.0:#{RIG_PRIMARY_PORT}", "#{CHAOS_UPSTREAM_HOST}:#{primary_port}")
  tp.upsert_proxy('secondary', "0.0.0.0:#{RIG_SECONDARY_PORT}", "#{CHAOS_UPSTREAM_HOST}:#{secondary_port}")
  tp.upsert_proxy('sse', "0.0.0.0:#{RIG_SSE_PORT}", "#{CHAOS_UPSTREAM_HOST}:#{primary_port}")
end

def failover_upstream_generations(setup)
  primary = 0
  secondary = 0
  (setup['upstreams'] || []).each do |u|
    case u['role']
    when 'primary'   then primary = (u['generation'] || 0).to_i
    when 'secondary' then secondary = (u['generation'] || 0).to_i
    end
  end
  [primary, secondary]
end

# ----- collection -----

def failover_scenario_files(dir)
  return [] unless Dir.exist?(dir)

  files = Dir.glob(File.join(dir, '*.yaml'))
  files.select! { |f| FAILOVER_RUN_RE.match?(File.basename(f)) } if FAILOVER_RUN_RE
  files.reject! { |f| FAILOVER_SKIP_RE.match?(File.basename(f)) } if FAILOVER_SKIP_RE
  files
end

def failover_slug(name)
  name.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '').slice(0, 60)
end

# Shared toxiproxy connection + (lazily-spawned) failover upstream. Built once
# per process; the single failover upstream is reused across f01-f05.
module FailoverShared
  @lock = Mutex.new
  @toxiproxy = nil
  @setup_error = nil
  @setup_done = false
  @failover_port = nil

  class << self
    def toxiproxy
      ensure_setup
      @toxiproxy
    end

    def setup_error
      ensure_setup
      @setup_error
    end

    # One fixture upstream (generation 0) behind both proxies for the whole
    # failover suite. Identical content on both legs proves failover routing,
    # not divergent data (that's the ordering rig).
    def failover_upstream_port
      ensure_setup
      @lock.synchronize do
        @failover_port ||= FailoverUpstreams.spawn(0).last
      end
    end

    private

    def ensure_setup
      @lock.synchronize do
        return if @setup_done

        @setup_done = true
        missing = %w[CHAOS_API_DELIVERY_BIN CHAOS_FIXTURE_DIR CHAOS_SDK_KEYS_FILE]
                  .find { |k| ENV.fetch(k, nil).to_s.empty? }
        if missing
          @setup_error = "#{missing} not set — run scripts/run-failover-chaos.sh to boot the rig"
          return
        end
        tp = FailoverToxiproxy.new(TOXIPROXY_URL)
        unless tp.ping
          @setup_error = "toxiproxy not reachable at #{TOXIPROXY_URL} — run scripts/run-failover-chaos.sh first"
          return
        end
        @toxiproxy = tp
      end
    end
  end
end

# ----- generate Minitest methods -----

class FailoverChaosTest < Minitest::Test
  # generated at load time; one method per scenario test entry
end

# Failover suite: one shared upstream, faults on the primary leg.
failover_scenario_files(FAILOVER_SCEN_DIR).each do |path|
  doc = begin
    YAML.safe_load_file(path, aliases: true)
  rescue StandardError => e
    warn "failover: failed to parse #{path}: #{e.message}"
    next
  end
  base = File.basename(path, '.yaml')
  (doc['tests'] || []).each do |run|
    method = "test_#{failover_slug(base)}_#{failover_slug(run['name'])}"
    FailoverChaosTest.send(:define_method, method) do
      skip FailoverShared.setup_error if FailoverShared.setup_error

      tp = FailoverShared.toxiproxy
      port = FailoverShared.failover_upstream_port
      failover_reconfigure_proxies(tp, port, port)
      passed, failed, details = failover_run_scenario(tp, run, ordering: false)
      details.each { |line| puts line }
      assert_equal 0, failed, "#{failed} expectation(s) failed in #{run['name']}"
      assert passed >= 0
    end
  end
end

# Ordering suite: two upstreams at divergent generations, spawned per scenario.
failover_scenario_files(ORDERING_SCEN_DIR).each do |path|
  doc = begin
    YAML.safe_load_file(path, aliases: true)
  rescue StandardError => e
    warn "ordering: failed to parse #{path}: #{e.message}"
    next
  end
  base = File.basename(path, '.yaml')
  (doc['tests'] || []).each do |run|
    method = "test_#{failover_slug(base)}_#{failover_slug(run['name'])}"
    FailoverChaosTest.send(:define_method, method) do
      skip FailoverShared.setup_error if FailoverShared.setup_error

      tp = FailoverShared.toxiproxy
      primary_gen, secondary_gen = failover_upstream_generations(run['setup'] || {})
      primary_pid, primary_port = FailoverUpstreams.spawn(primary_gen)
      secondary_pid, secondary_port = FailoverUpstreams.spawn(secondary_gen)
      begin
        failover_reconfigure_proxies(tp, primary_port, secondary_port)
        passed, failed, details = failover_run_scenario(tp, run, ordering: true)
        details.each { |line| puts line }
        assert_equal 0, failed, "#{failed} expectation(s) failed in #{run['name']}"
        assert passed >= 0
      ensure
        FailoverUpstreams.kill(primary_pid)
        FailoverUpstreams.kill(secondary_pid)
      end
    end
  end
end

if ENV['CHAOS_LIST_TESTS'] == '1'
  FailoverChaosTest.instance_methods(false).sort.each { |m| puts m }
  exit 0
end
