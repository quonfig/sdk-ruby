# frozen_string_literal: true

# Chaos event application for the default chaos suite (chaos/test_chaos.rb):
# maps a scenario's inject / clear / process step onto toxiproxy calls.
# Extracted so it can be unit-tested against a fake toxiproxy
# (test/test_chaos_injection.rb).

# ----- chaos injection -----

# A chaos step this rig cannot apply. Raised, never printed as a no-op: a
# scenario whose fault never happened must not pass (qfg-6vno.6).
class ChaosUnsupportedStep < StandardError; end

# HTTP-level faults. toxiproxy is TCP-only, so it cannot answer an HTTP status;
# the ITD scenario that uses them (scenarios-http-proxy/08) says it is not
# runnable until an HTTP-aware fault proxy exists (WS4).
CHAOS_HTTP_STATUS_INJECTS = %w[sse_http_status http_status].freeze

CHAOS_HTTP_PROXY_SKIP_REASON =
  'needs an HTTP-aware fault proxy (WS4): toxiproxy is TCP-only and cannot return an HTTP status ' \
  '(%s); the gate until then is Tier-1 supervisor Test 8, test/test_supervisor_auth_failure.rb'

# The SKIPPED reason for a scenario whose chaos steps include an inject this
# rig cannot model, or nil when every step is supported. Decided by shape
# before the run, so the scenario is reported SKIPPED rather than run without
# its fault.
def chaos_unsupported_step_reason(events)
  keys = (events || []).flat_map { |ev| (ev['inject'] || {}).keys & CHAOS_HTTP_STATUS_INJECTS }.uniq
  return nil if keys.empty?

  format(CHAOS_HTTP_PROXY_SKIP_REASON, keys.join(', '))
end

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
  if (keys = inj.keys & CHAOS_HTTP_STATUS_INJECTS).any?
    raise ChaosUnsupportedStep, "inject #{inj.inspect}: #{format(CHAOS_HTTP_PROXY_SKIP_REASON, keys.join(', '))}"
  end

  if inj['proxy'] && inj['toxic']
    toxic = inj['toxic']
    tp.add_toxic(inj['proxy'], name, toxic['type'].to_s, 'downstream',
                 toxic['attributes'] || {})
    return { 'proxy' => inj['proxy'], 'toxic' => name }
  end
  raise ChaosUnsupportedStep, "inject: unknown shape #{inj.inspect}"
end

def chaos_clear_inject(tp, st)
  return if st.nil? || st.empty?

  tp.remove_toxic(st['proxy'], st['toxic']) if st['toxic'] && st['proxy']
  (st['enable'] || []).each { |p| tp.set_enabled(p, true) }
end

def chaos_apply_process(tp, p)
  raise ChaosUnsupportedStep, "process: unknown action #{p['action'].inspect}" unless p['action'] == 'kill_sse_proxy'

  count = (p['count'] || 1).to_i
  interval_ms = (p['interval_ms'] || 1000).to_i
  count.times do |i|
    tp.set_enabled('sse', false)
    sleep 0.2
    tp.set_enabled('sse', true)
    sleep [0.0, (interval_ms - 200) / 1000.0].max if i < count - 1
  end
end
