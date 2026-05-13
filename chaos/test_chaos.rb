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

# ----- paths -----

CHAOS_HERE       = File.expand_path(__dir__)
CHAOS_SDK_ROOT   = File.expand_path('..', CHAOS_HERE)
CHAOS_REPO_ROOT  = File.expand_path('..', CHAOS_SDK_ROOT)
CHAOS_SCENARIOS  = File.join(CHAOS_REPO_ROOT, 'integration-test-data', 'chaos', 'scenarios')

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

# ----- SDK probe -----

class ChaosProbe
  attr_reader :lock, :log_lock

  def initialize
    @lock           = Mutex.new
    @log_lock       = Mutex.new
    @conn_state     = 'initializing' # initializing|connected|reconnecting|falling_back|disconnected
    @last_refresh_ms = 0
    @conn_attempts  = 0
    @restart_layer1 = 0
    @restart_layer2 = 0
    @fallback_active = false
    @process_crashed = false
    @logs = []
  end

  attr_accessor :process_crashed

  # Synthesize a state edge based on the SDK's :connection_state symbol.
  # Mirrors sdk-python's ChaosProbe.on_sse_state semantics:
  #   :connected      -> 'connected', conn_attempts++
  #   :falling_back   -> 'falling_back', fallback_active = true
  #   :disconnected   -> 'disconnected'
  #   :initializing   -> 'initializing'
  def absorb_sdk_state(sdk_state)
    @lock.synchronize do
      case sdk_state
      when :connected
        @conn_state = 'connected'
        @conn_attempts += 1
      when :falling_back
        # transition into fallback: if we were previously connected, that's a
        # Layer 1 restart edge.
        @restart_layer1 += 1 if @conn_state == 'connected'
        @conn_state = 'falling_back'
        @fallback_active = true
      when :disconnected
        # transition out of connected (but NOT into falling_back) -> reconnecting
        # If we were already disconnected/initializing, stay that way.
        if @conn_state == 'connected'
          @restart_layer1 += 1
          @conn_state = 'reconnecting'
        elsif @conn_state == 'reconnecting'
          # keep reconnecting
        else
          @conn_state = 'disconnected'
        end
        @fallback_active = false
      when :initializing
        # first observation; no edge work
        @conn_state = 'initializing' if @conn_state == 'initializing'
        @fallback_active = false
      end
    end
  end

  def on_config_update
    @lock.synchronize do
      @last_refresh_ms = (Time.now.to_f * 1000).to_i
    end
  end

  def bump_restart_layer2(by = 1)
    @lock.synchronize { @restart_layer2 += by }
  end

  def log(level, msg)
    line = "level=#{level.to_s.downcase} #{msg}"
    @log_lock.synchronize { @logs << line }
    # Mirror sdk-python/sdk-go: an onConfigUpdate callback throw counts as a
    # Layer 1 restart for chaos scenario 10. Match the user-callback recovery
    # log lines case-insensitively. The current sdk-ruby log line is
    # "onConfigUpdate callback raised" (qfg-47c2.30); historical phrasing
    # ("callback threw", "Error applying SSE envelope") is kept for back-compat
    # with older SDK builds run against this harness.
    return unless msg.to_s =~ /onConfigUpdate callback (raised|threw|panicked)|callback (raised|threw|panicked)|Error applying SSE envelope/i

    @lock.synchronize { @restart_layer1 += 1 }
  end

  def snapshot
    @lock.synchronize do
      {
        conn_state: @conn_state,
        last_refresh_ms: @last_refresh_ms,
        restart_layer1: @restart_layer1,
        restart_layer2: @restart_layer2,
        fallback_active: @fallback_active,
        process_crashed: @process_crashed
      }
    end
  end

  def sdk_metric(name, labels)
    @lock.synchronize do
      case name
      when 'quonfig_sdk_worker_restart_total'
        case labels['layer']
        when '1' then @restart_layer1.to_f
        when '2' then @restart_layer2.to_f
        else (@restart_layer1 + @restart_layer2).to_f
        end
      when 'quonfig_sse_connect_attempts_total'
        @conn_attempts.to_f
      else
        0.0
      end
    end
  end

  def log_matches(level, regex)
    @log_lock.synchronize do
      n = 0
      @logs.each do |line|
        next if level && !level.empty? && !line.downcase.include?("level=#{level.downcase}")

        n += 1 if regex.match?(line)
      end
      n
    end
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

# ----- chaos injection -----

def chaos_apply_inject(tp, inj)
  name = inj['name'] || 'anon'
  if inj.key?('sse_silent_stall_after_ms')
    tp.add_toxic('sse', name, 'timeout', 'downstream',
                 { 'timeout' => inj['sse_silent_stall_after_ms'] })
    return { 'proxy' => 'sse', 'toxic' => name }
  end
  if inj.key?('sse_latency_ms')
    tp.add_toxic('sse', name, 'latency', 'downstream',
                 { 'latency' => inj['sse_latency_ms'] })
    return { 'proxy' => 'sse', 'toxic' => name }
  end
  if inj.key?('sse_bandwidth_kbps')
    tp.add_toxic('sse', name, 'bandwidth', 'downstream',
                 { 'rate' => inj['sse_bandwidth_kbps'] })
    return { 'proxy' => 'sse', 'toxic' => name }
  end
  if inj.key?('sse_down_ms')
    tp.set_enabled('sse', false)
    return { 'enable' => ['sse'] }
  end
  if inj.key?('both_down_ms')
    tp.set_enabled('sse', false)
    tp.set_enabled('http', false)
    return { 'enable' => %w[sse http] }
  end
  if inj.key?('sse_half_open_after_bytes')
    # Toxiproxy is TCP-only and can't truly model "server returns 200 then
    # closes after N bytes" — the limit_data toxic this used to call only
    # trips on the NEXT upstream byte, which for SSE is the 30s heartbeat,
    # outside the typical within_ms=15s window. The closest TCP-only analog
    # is to disable the proxy: existing SSE connections drop, new attempts
    # are refused. Leave it disabled until the matching `clear` step so the
    # SDK's reconnect attempts fail visibly (ld-eventsource fires on_error
    # on ECONNREFUSED, where it may stay silent on clean FIN). qfg-47c2.29.
    tp.set_enabled('sse', false)
    return { 'enable' => ['sse'] }
  end
  if inj.key?('sse_http_status')
    # toxiproxy is TCP-only; HTTP status injection is a no-op here.
    puts "inject: sse_http_status=#{inj['sse_http_status']} not supported (toxiproxy TCP-only)"
    return {}
  end
  if inj['proxy'] && inj['toxic']
    toxic = inj['toxic']
    tp.add_toxic(inj['proxy'], name, toxic['type'].to_s, 'downstream',
                 toxic['attributes'] || {})
    return { 'proxy' => inj['proxy'], 'toxic' => name }
  end
  nil
end

def chaos_clear_inject(tp, st)
  return if st.nil? || st.empty?

  tp.remove_toxic(st['proxy'], st['toxic']) if st['toxic'] && st['proxy']
  (st['enable'] || []).each { |p| tp.set_enabled(p, true) }
end

def chaos_apply_process(tp, p)
  if p['action'] == 'kill_sse_proxy'
    count = (p['count'] || 1).to_i
    interval_ms = (p['interval_ms'] || 1000).to_i
    count.times do |i|
      tp.set_enabled('sse', false)
      sleep 0.2
      tp.set_enabled('sse', true)
      sleep [0.0, (interval_ms - 200) / 1000.0].max if i < count - 1
    end
  else
    puts "process: unknown action #{p['action'].inspect} — no-op"
  end
end

# ----- expression evaluator -----

RE_CONN_STATE_EQ = /\Aclient\.connectionState\(\)\s*(==|!=)\s*'([^']+)'\z/
RE_FALLBACK_EQ   = /\Aclient\.fallbackPollerActive\(\)\s*==\s*(true|false)\z/
RE_PROC_ALIVE_EQ = /\Aclient\.processStillAlive\(\)\s*==\s*(true|false)\z/
RE_LAST_REFRESH  = /\Aclient\.lastSuccessfulRefresh\(\)\s*(>=|>|<=|<|==)\s*\(now\(\)\s*-\s*(\d+)\)\z/
RE_SDK_METRIC    = /\Aclient\.sdkMetric\(\s*'([^']+)'\s*(?:,\s*layer=\s*'([^']+)'\s*)?\)\s*(>=|<=|==|!=|<|>)\s*(\d+)\z/
RE_SERVER_METRIC = /\Aserver_metric\(\s*'([^']+)'\s*\)\s*(>=|<=|==|!=|<|>)\s*(\d+)\z/
RE_SDK_LOG       = %r{\Aclient\.sdkLog\(\s*'([^']+)'\s*,\s*/(.+)/i\s*\)\s*(>=|<=|==|!=|<|>)\s*(\d+)\z}

def chaos_split_outside_quotes(expr, sep)
  out = []
  in_sq = false
  in_re = false
  start = 0
  i = 0
  while i < expr.length
    c = expr[i]
    if c == "'" && !in_re
      in_sq = !in_sq
    elsif c == '/' && !in_sq
      in_re = !in_re
    end
    if !in_sq && !in_re && expr[i, sep.length] == sep
      out << expr[start...i]
      start = i + sep.length
      i += sep.length
      next
    end
    i += 1
  end
  out << expr[start..]
  out
end

def chaos_compare(op, a, b)
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

def chaos_eval_leaf(expr, probe, server_metric)
  expr = expr.strip
  if (m = RE_CONN_STATE_EQ.match(expr))
    op = m[1]
    want = m[2]
    snap = probe.snapshot
    got = snap[:conn_state]
    ok = op == '==' ? got == want : got != want
    return [ok, "connectionState=#{got} #{op} #{want}"]
  end
  if (m = RE_FALLBACK_EQ.match(expr))
    want = m[1] == 'true'
    got = probe.snapshot[:fallback_active]
    return [got == want, "fallbackPollerActive=#{got} want #{want}"]
  end
  if (m = RE_PROC_ALIVE_EQ.match(expr))
    want = m[1] == 'true'
    alive = !probe.snapshot[:process_crashed]
    return [alive == want, "processStillAlive=#{alive} want #{want}"]
  end
  if (m = RE_LAST_REFRESH.match(expr))
    op  = m[1]
    ago = m[2].to_i
    last = probe.snapshot[:last_refresh_ms]
    threshold = (Time.now.to_f * 1000).to_i - ago
    ok = chaos_compare(op, last, threshold)
    return [ok, "lastSuccessfulRefresh=#{last} #{op} (now()-#{ago})=#{threshold}"]
  end
  if (m = RE_SDK_METRIC.match(expr))
    metric = m[1]
    layer = m[2]
    op = m[3]
    want = m[4].to_f
    labels = layer ? { 'layer' => layer } : {}
    got = probe.sdk_metric(metric, labels)
    ok = chaos_compare(op, got, want)
    return [ok, "sdkMetric(#{metric},layer=#{layer || ''})=#{got} #{op} #{want}"]
  end
  if (m = RE_SERVER_METRIC.match(expr))
    name = m[1]
    op = m[2]
    want = m[3].to_f
    got = server_metric.call(name)
    ok = chaos_compare(op, got, want)
    return [ok, "server_metric(#{name})=#{got} #{op} #{want}"]
  end
  if (m = RE_SDK_LOG.match(expr))
    level = m[1]
    pattern = m[2]
    op = m[3]
    want = m[4].to_f
    regex = Regexp.new(pattern, Regexp::IGNORECASE)
    got = probe.log_matches(level, regex).to_f
    ok = chaos_compare(op, got, want)
    return [ok, "sdkLog(#{level},/#{pattern}/i)=#{got} #{op} #{want}"]
  end
  [false, "unrecognized expression: #{expr}"]
end

def chaos_evaluate(expr, probe, server_metric)
  expr = expr.to_s.strip
  return [true, ''] if expr.empty?

  if expr.include?(' OR ')
    parts = chaos_split_outside_quotes(expr, ' OR ')
    reasons = []
    parts.each do |p|
      ok, why = chaos_evaluate(p, probe, server_metric)
      return [true, ''] if ok

      reasons << why
    end
    return [false, "OR: #{reasons.join(' | ')}"]
  end
  if expr.include?(' AND ')
    parts = chaos_split_outside_quotes(expr, ' AND ')
    parts.each do |p|
      ok, why = chaos_evaluate(p, probe, server_metric)
      return [false, "AND: #{why}"] unless ok
    end
    return [true, '']
  end
  chaos_eval_leaf(expr, probe, server_metric)
end

# ----- scenario runner -----

# Build the Quonfig::Client configured to talk through the chaos ports.
def chaos_build_client(probe, _setup)
  options = Quonfig::Options.new(
    sdk_key: 'test-backend-key',
    api_urls: ["http://127.0.0.1:#{CHAOS_HTTP_PORT}"],
    enable_sse: true,
    enable_polling: true,
    poll_interval: 60,
    initialization_timeout_sec: 15,
    on_init_failure: Quonfig::Options::ON_INITIALIZATION_FAILURE::RETURN,
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

  client = Quonfig::Client.new(options)
  client.on_update { probe.on_config_update }
  client
end

# Poller thread: bridges client.connection_state into the probe and watches
# worker_restart_total deltas for Layer 2 attribution. Source of truth for
# the probe's state machine.
def chaos_spawn_poller(client, probe, stop_flag)
  Thread.new do
    Thread.current.name = 'chaos-poller' if Thread.current.respond_to?(:name=)
    prev_l2 = client.worker_restart_total
    until stop_flag.set?
      begin
        state = client.connection_state
        probe.absorb_sdk_state(state)

        cur = client.worker_restart_total
        if cur > prev_l2
          probe.bump_restart_layer2(cur - prev_l2)
          prev_l2 = cur
        end
      rescue StandardError => e
        # never let the poller die — log and keep going
        probe.log(:warn, "chaos poller error: #{e.class}: #{e.message}")
      end
      stop_flag.wait(0.05) # 50ms
    end
  end
end

# Tiny stop-event so threads can wait with a timeout.
class ChaosStopFlag
  def initialize
    @m = Mutex.new
    @c = ConditionVariable.new
    @set = false
  end

  def set?
    @m.synchronize { @set }
  end

  def set!
    @m.synchronize do
      @set = true
      @c.broadcast
    end
  end

  def wait(seconds)
    @m.synchronize do
      return if @set

      @c.wait(@m, seconds)
    end
  end
end

def chaos_run_scenario(tp, run)
  tp.clear_toxics('sse')
  tp.clear_toxics('http')
  tp.set_enabled('sse', true)
  tp.set_enabled('http', true)

  probe = ChaosProbe.new
  setup = run['setup'] || {}
  user_callback_mode = setup['user_callback']
  wall_clock_ms = ((setup['wall_clock_seconds'] || 30).to_f * 1000).to_i

  # Hook the internal logger so every quonfig log line lands in the probe.
  prev_user_logger = Quonfig::InternalLogger.user_logger
  Quonfig::InternalLogger.user_logger = ChaosLoggerTap.new(probe)

  client = nil
  poller = nil
  stop_flag = ChaosStopFlag.new
  injection_states = {}
  scheduled_threads = []

  begin
    begin
      client = chaos_build_client(probe, setup)
    rescue StandardError => e
      probe.process_crashed = true
      probe.log(:error, "init failed: #{e.class}: #{e.message}")
    end

    if client && user_callback_mode == 'throw'
      # Wrap on_update to throw — exercises Layer 1 callback-throw scenario.
      client.on_update do
        probe.on_config_update
        raise 'simulated user-callback throw for chaos scenario 10'
      end
    end

    poller = chaos_spawn_poller(client, probe, stop_flag) if client

    baseline_ms = (Time.now.to_f * 1000).to_i

    # Schedule chaos events.
    (run['chaos'] || []).each do |ev|
      at = (ev['at_ms'] || 0).to_i
      scheduled_threads << Thread.new do
        sleep(at / 1000.0)
        begin
          if ev['inject']
            st = chaos_apply_inject(tp, ev['inject'])
            injection_states[ev['inject']['name']] = st if ev['inject']['name']
            puts "[#{at}ms] inject #{ev['inject'].inspect}"
          elsif ev['clear']
            chaos_clear_inject(tp, injection_states[ev['clear']])
            injection_states.delete(ev['clear'])
            puts "[#{at}ms] clear #{ev['clear']}"
          elsif ev['process']
            chaos_apply_process(tp, ev['process'])
            puts "[#{at}ms] process #{ev['process'].inspect}"
          end
        rescue StandardError => e
          puts "[#{at}ms] chaos event failed: #{e.class}: #{e.message}"
        end
      end
    end

    states = (run['expectations'] || []).each_with_index.map do |e, i|
      {
        idx: i, exp: e, passed: false, failed: false,
        hit_at: nil, held_since: nil, last_reason: ''
      }
    end

    server_metric = ->(_name) { 0.0 }
    poll_interval = CHAOS_POLL_MS / 1000.0

    loop do
      elapsed = (Time.now.to_f * 1000).to_i - baseline_ms
      break if elapsed >= wall_clock_ms

      all_terminal = true
      states.each do |s|
        next if s[:passed] || s[:failed]

        ok, why = chaos_evaluate(s[:exp]['assert'], probe, server_metric)
        s[:last_reason] = why
        if ok
          if s[:held_since].nil?
            s[:held_since] = (Time.now.to_f * 1000).to_i
            s[:hit_at] = elapsed
          end
          hold_for = (s[:exp]['must_hold_for_ms'] || 0).to_i
          s[:passed] = true if hold_for <= 0 || ((Time.now.to_f * 1000).to_i - s[:held_since]) >= hold_for
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

    details = []
    passed = 0
    failed = 0
    states.each do |s|
      exp = s[:exp]
      label = "exp[#{s[:idx]}] within=#{exp['within_ms']}ms " \
              "hold=#{exp['must_hold_for_ms'] || 0}ms: #{exp['assert']}"
      if s[:passed]
        passed += 1
        details << "PASS  #{label} (hit at #{s[:hit_at]}ms)"
      else
        failed += 1
        details << "FAIL  #{label} — last: #{s[:last_reason]}"
      end
    end
    snap = probe.snapshot
    details << "summary: #{passed} passed, #{failed} failed " \
               "(state=#{snap[:conn_state]}, restartLayer1=#{snap[:restart_layer1]}, " \
               "restartLayer2=#{snap[:restart_layer2]}, fallback=#{snap[:fallback_active]}, " \
               "lastRefreshMs=#{snap[:last_refresh_ms]})"

    [passed, failed, details]
  ensure
    stop_flag.set!
    scheduled_threads.each do |t|
      t.join(1.0)
    rescue StandardError
      nil
    end
    begin
      poller&.join(2.0)
    rescue StandardError
      nil
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
  return [] unless Dir.exist?(CHAOS_SCENARIOS)

  Dir.glob(File.join(CHAOS_SCENARIOS, '*.yaml'))
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
      doc = YAML.safe_load_file(f, aliases: true)
    rescue StandardError => e
      warn "chaos: failed to parse #{f}: #{e.class}: #{e.message}"
      next
    end
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
    skip ChaosShared.setup_error if ChaosShared.setup_error

    tp = ChaosShared.toxiproxy
    passed, failed, details = chaos_run_scenario(tp, run)
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
