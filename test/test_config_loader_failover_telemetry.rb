# frozen_string_literal: true

require 'test_helper'
require 'webrick'
require 'socket'
require 'json'

# End-to-end failover-telemetry call-site tests (qfg-41nh.18). These drive REAL
# fetch cycles through ConfigLoader against fixture upstreams and assert the
# shared FailoverAggregator recorded the right signals — proving the record
# calls actually fire on the hedge, resolved-from, and reject-older-guard paths
# (not just that the aggregator can count in isolation).
#
# Mirrors sdk-go's quonfig_failover_telemetry_test.go (a real hedge+secondary
# install and a guard rejection asserted against the emitted counters).
class TestConfigLoaderFailoverTelemetry < Minitest::Test
  def setup
    super
    @servers = []
  end

  def teardown
    @servers.each do |s|
      s.shutdown
    rescue StandardError
      nil
    end
    super
  end

  def config_for(gen)
    { 'id' => "c-#{gen}", 'key' => 'fo.flag', 'type' => 'config',
      'valueType' => 'bool', 'default' => { 'rules' => [] } }
  end

  def envelope_json(gen)
    JSON.generate(
      'configs' => [config_for(gen)],
      'meta' => { 'version' => "gen-#{gen}", 'environment' => 'production', 'generation' => gen }
    )
  end

  def start_upstream(gen, delay_s: 0)
    log = WEBrick::Log.new(StringIO.new)
    server = WEBrick::HTTPServer.new(Port: 0, Logger: log, AccessLog: [])
    server.mount_proc '/api/v2/configs' do |_req, res|
      sleep delay_s if delay_s.positive?
      res.status = 200
      res['Content-Type'] = 'application/json'
      res['ETag'] = "gen-#{gen}-#{rand(1_000_000)}" # unique so a leg never 304s itself
      res.body = envelope_json(gen)
    end
    port = server.config[:Port]
    Thread.new { server.start }
    50.times do
      break if tcp_open?(port)

      sleep 0.05
    end
    @servers << server
    "http://127.0.0.1:#{port}"
  end

  def tcp_open?(port)
    TCPSocket.new('127.0.0.1', port).tap(&:close)
    true
  rescue StandardError
    false
  end

  def build_loader(urls, aggregator)
    options = Quonfig::Options.new(
      sdk_key: '1-test-sdk-key', api_urls: urls,
      enable_sse: false, fallback_poll_enabled: false,
      config_fetch_hedge_delay_ms: 200,
      config_fetch_hedge_abort_ms: 4000
    )
    Quonfig::ConfigLoader.new(Quonfig::ConfigStore.new, options, failover_aggregator: aggregator)
  end

  def poll_until_generation(loader, want, within_s)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within_s
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      return if loader.held_generation == want

      sleep 0.02
    end
    flunk "held generation did not reach #{want} within #{within_s}s (last = #{loader.held_generation})"
  end

  # Fast healthy primary: no hedge, resolved-from = primary. The aggregator sees
  # exactly one resolvedFromPrimary and nothing else — a healthy steady-state
  # client's failover signal.
  def test_fast_primary_records_resolved_from_primary_only
    aggregator = Quonfig::Telemetry::FailoverAggregator.new
    primary = start_upstream(41, delay_s: 0)
    secondary = start_upstream(42, delay_s: 0)

    loader = build_loader([primary, secondary], aggregator)
    loader.fetch!

    assert_equal 'primary', loader.resolved_from

    event = aggregator.drain_event
    refute_nil event, 'a successful install must record a resolved-from'
    f = event['failover']
    assert_equal 1, f['resolvedFromPrimary']
    assert_equal 0, f['resolvedFromSecondary']
    assert_equal 0, f['hedgeFired'], 'a fast primary must not fire the hedge'
    assert_equal 0, f['guardRejected']
  end

  # Slow primary + fast newer secondary: the hedge fires, the secondary install
  # wins. The aggregator records hedgeFired and resolvedFromSecondary. Then the
  # slow primary's OLDER generation lands late on subsequent refreshes and the
  # reject-older guard drops it — recording guardRejected.
  def test_hedge_fire_secondary_install_and_guard_rejection
    aggregator = Quonfig::Telemetry::FailoverAggregator.new
    primary = start_upstream(41, delay_s: 1.0)  # slow + OLDER
    secondary = start_upstream(42, delay_s: 0)  # fast + NEWER

    loader = build_loader([primary, secondary], aggregator)
    loader.fetch!

    # The hedge fired the secondary and installed its newer 42.
    poll_until_generation(loader, 42, 4)
    assert_equal 'secondary', loader.resolved_from

    # Drive extra refreshes so the slow primary's older 41 lands and is dropped
    # by the reject-older guard (held generation stays 42).
    3.times { loader.fetch! }
    assert_equal 42, loader.held_generation, 'reject-older must keep the client on 42'

    event = aggregator.drain_event
    refute_nil event
    f = event['failover']
    assert_operator f['hedgeFired'], :>=, 1, 'the hedge fired against the slow primary'
    assert_operator f['resolvedFromSecondary'], :>=, 1, 'the secondary served an install'
    assert_operator f['guardRejected'], :>=, 1, 'the slow older primary was guard-rejected'
  end

  # qfg-rr5b — an EQUAL-generation re-delivery is a silent no-op, not a guard
  # rejection. Two server behaviors re-deliver the held envelope constantly:
  # api-delivery's SSE `sendInitialConfig` re-sends the current envelope on
  # every connect (SDK clients send no Last-Event-Id), and a config poll on an
  # empty per-leg ETag slot (fresh transport, reconnect, fallback-poller engage
  # fetch) returns a full 200 at the same generation. Counting those as
  # `guardRejected` polluted the sdk_failover alerting signal, which is
  # supposed to mean "a leg tried to move us BACKWARDS" — a steady-state client
  # showed guardRejected >= 1 from init alone. The drop itself is unchanged:
  # still not installed, still :not_modified, still advances liveness.
  def test_same_generation_redelivery_is_not_counted_as_guard_rejected
    aggregator = Quonfig::Telemetry::FailoverAggregator.new
    primary = start_upstream(10, delay_s: 0)

    loader = build_loader([primary], aggregator)
    loader.fetch! # establishes held_generation = 10

    assert_equal 10, loader.held_generation

    # Drain the resolved-from-primary from the initial install so we isolate
    # the guard signal.
    aggregator.drain_event

    # The same envelope the client already holds, re-delivered (SSE reconnect
    # resend / cold-ETag poll). Twice, so a counter that ticks is unmissable.
    same = Quonfig::ConfigEnvelope.new(
      configs: [config_for(10)],
      meta: { 'version' => 'gen-10', 'environment' => 'production', 'generation' => 10 }
    )

    assert_equal :not_modified, loader.apply_envelope(same),
                 'an equal-generation envelope must still be a no-op install'
    assert_equal :not_modified, loader.apply_envelope(same)
    assert_equal 10, loader.held_generation, 'an equal-generation re-delivery must not move the client'

    event = aggregator.drain_event
    guard_rejected = event ? event['failover']['guardRejected'] : 0

    assert_equal 0, guard_rejected,
                 'an equal-generation re-delivery must NOT be counted as guardRejected'
  end

  # The other half of qfg-rr5b: a STRICTLY older payload is still the thing
  # guardRejected exists to report, and it still counts — exactly once.
  def test_strictly_older_redelivery_is_counted_as_guard_rejected
    aggregator = Quonfig::Telemetry::FailoverAggregator.new
    primary = start_upstream(10, delay_s: 0)

    loader = build_loader([primary], aggregator)
    loader.fetch!

    assert_equal 10, loader.held_generation
    aggregator.drain_event

    older = Quonfig::ConfigEnvelope.new(
      configs: [config_for(9)],
      meta: { 'version' => 'gen-9', 'environment' => 'production', 'generation' => 9 }
    )

    assert_equal :not_modified, loader.apply_envelope(older)
    assert_equal 10, loader.held_generation, 'a stale snapshot must not regress the client'

    event = aggregator.drain_event

    refute_nil event, 'a strictly older payload must still record a failover signal'
    assert_equal 1, event['failover']['guardRejected'],
                 'a STRICTLY older payload is exactly what guardRejected is for'
  end

  # An UNVERSIONED snapshot (generation <= 0) carries no ordering info, so the
  # carve-out lets it through untouched — it is neither dropped as older nor
  # counted. Pinned here so the strict-older narrowing cannot quietly change it.
  def test_unversioned_snapshot_is_not_guard_rejected
    aggregator = Quonfig::Telemetry::FailoverAggregator.new
    primary = start_upstream(10, delay_s: 0)

    loader = build_loader([primary], aggregator)
    loader.fetch!

    assert_equal 10, loader.held_generation
    aggregator.drain_event

    unversioned = Quonfig::ConfigEnvelope.new(
      configs: [config_for(0)],
      meta: { 'version' => 'gen-0', 'environment' => 'production', 'generation' => 0 }
    )
    loader.apply_envelope(unversioned)

    event = aggregator.drain_event
    guard_rejected = event ? event['failover']['guardRejected'] : 0

    assert_equal 0, guard_rejected, 'the unversioned carve-out must never be counted as guardRejected'
  end

  # A stale SSE snapshot (older generation) against an established client is
  # dropped by the same reject-older guard — proving the SSE message path also
  # records guardRejected (source_index nil, so no resolved-from is counted).
  def test_sse_guard_rejection_records_guard_rejected
    aggregator = Quonfig::Telemetry::FailoverAggregator.new
    primary = start_upstream(10, delay_s: 0)

    loader = build_loader([primary], aggregator)
    loader.fetch! # establishes held_generation = 10
    assert_equal 10, loader.held_generation

    # Drain the resolved-from-primary from the initial install so we isolate the
    # SSE guard signal.
    aggregator.drain_event

    # A late SSE snapshot at an OLDER generation (5) must be rejected.
    stale = Quonfig::ConfigEnvelope.new(
      configs: [config_for(5)],
      meta: { 'version' => 'gen-5', 'environment' => 'production', 'generation' => 5 }
    )
    loader.apply_envelope(stale)

    assert_equal 10, loader.held_generation, 'stale SSE snapshot must not regress the client'

    event = aggregator.drain_event
    refute_nil event, 'a guard-rejected SSE snapshot must record a failover signal'
    f = event['failover']
    assert_equal 1, f['guardRejected']
    assert_equal 0, f['resolvedFromSecondary'], 'SSE carries no HTTP leg — no resolved-from'
    assert_equal 0, f['resolvedFromPrimary']
  end
end
