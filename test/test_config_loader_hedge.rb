# frozen_string_literal: true

require 'test_helper'
require 'webrick'
require 'socket'
require 'json'

# Parallel-failover hedge unit tests (qfg-7h5d.1.14.6). These pin the behaviors
# the chaos ordering scenarios assert at the unit level, where a per-leg request
# counter can prove the "secondary is never contacted on a fast primary" contract
# that the chaos rig (no server-side counter) cannot:
#
#   o01 cold-standby     — a fast primary wins inside the hedge delay; the
#                          secondary is NEVER contacted (zero extra load).
#   o05 secondary-newer  — a SLOW older primary loses to a fast newer secondary;
#                          the late older primary does not regress the client.
#   o03 heal-forward     — a SLOW newer primary heals forward after a fast older
#                          secondary seeds readiness.
#
# They use only the public ConfigLoader/Client surface and the default hedge
# timings, so the file also compiles + runs against the pre-hedge sequential
# fetch! to capture the RED baseline (the slow-primary cases hold the primary's
# generation and never contact the secondary).
class TestConfigLoaderHedge < Minitest::Test
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
    { 'id' => "c-#{gen}", 'key' => 'hedge.flag', 'type' => 'config',
      'valueType' => 'bool', 'default' => { 'rules' => [] } }
  end

  def envelope_json(gen)
    JSON.generate(
      'configs' => [config_for(gen)],
      'meta' => { 'version' => "gen-#{gen}", 'environment' => 'production', 'generation' => gen }
    )
  end

  # Spawns a fixture upstream pinned to `gen`, optionally delayed by `delay_s`
  # before it answers, counting every request it receives. Returns [url, hits]
  # where hits is a thread-safe counter.
  def start_upstream(gen, delay_s: 0)
    hits = AtomicCounter.new
    log = WEBrick::Log.new(StringIO.new)
    server = WEBrick::HTTPServer.new(Port: 0, Logger: log, AccessLog: [])
    server.mount_proc '/api/v2/configs' do |_req, res|
      hits.increment
      sleep delay_s if delay_s.positive?
      res.status = 200
      res['Content-Type'] = 'application/json'
      res['ETag'] = "gen-#{gen}"
      res.body = envelope_json(gen)
    end
    port = server.config[:Port]
    Thread.new { server.start }
    50.times do
      break if tcp_open?(port)

      sleep 0.05
    end
    @servers << server
    ["http://127.0.0.1:#{port}", hits]
  end

  def tcp_open?(port)
    TCPSocket.new('127.0.0.1', port).tap(&:close)
    true
  rescue StandardError
    false
  end

  # Minimal thread-safe counter so the upstream can prove zero/exact contact.
  class AtomicCounter
    def initialize
      @mutex = Mutex.new
      @n = 0
    end

    def increment
      @mutex.synchronize { @n += 1 }
    end

    def value
      @mutex.synchronize { @n }
    end
  end

  def build_loader(urls)
    options = Quonfig::Options.new(
      sdk_key: '1-test-sdk-key', api_urls: urls,
      enable_sse: false, fallback_poll_enabled: false,
      # Short hedge delay so the test is fast; abort comfortably exceeds the 1s
      # slow-primary latency so the late primary heals/regress-tests rather than
      # being aborted.
      config_fetch_hedge_delay_ms: 200,
      config_fetch_hedge_abort_ms: 4000
    )
    Quonfig::ConfigLoader.new(Quonfig::ConfigStore.new, options)
  end

  def poll_until_generation(loader, want, within_s)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within_s
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      return if loader.held_generation == want

      sleep 0.02
    end
    flunk "held generation did not reach #{want} within #{within_s}s (last = #{loader.held_generation})"
  end

  # o01 cold-standby: both legs healthy and fast, secondary newer. A fast primary
  # answers well inside the hedge delay, so the secondary is NEVER contacted. The
  # loader holds the primary's (lower) generation and resolved_from stays
  # 'primary'. This is the cold-standby proof the chaos rig cannot make.
  def test_fast_primary_never_contacts_secondary
    primary_url, primary_hits = start_upstream(41, delay_s: 0)
    secondary_url, secondary_hits = start_upstream(42, delay_s: 0)

    loader = build_loader([primary_url, secondary_url])
    loader.fetch!

    assert_equal 41, loader.held_generation,
                 'fast primary wins; secondary 42 must not be installed (cold standby)'
    assert_equal 'primary', loader.resolved_from
    assert_equal 1, loader.install_count, 'only the primary install — no fire-then-reject churn'
    assert_equal 0, secondary_hits.value,
                 'secondary contacted — a fast primary must never trigger the hedge'
    assert_operator primary_hits.value, :>=, 1, 'primary was never contacted'
  end

  # o05 secondary-newer-wins: the primary is SLOW and serves the OLDER generation
  # (41); the secondary is fast and serves the NEWER generation (42). The hedge
  # fires the secondary once the hedge delay elapses (primary still slow),
  # installs 42, latches ready off it; when the slow primary's older 41 lands late
  # the reject-older guard drops it.
  #
  # On the pre-hedge sequential fetch! the primary is tried first; it answers
  # (slowly, but inside the per-URL timeout) with 41, the secondary is never
  # contacted, and the loader holds 41 — RED. The hedge makes it hold 42 (GREEN).
  def test_slow_older_primary_loses_to_fast_newer_secondary
    primary_url, = start_upstream(41, delay_s: 1.0)
    secondary_url, secondary_hits = start_upstream(42, delay_s: 0)

    loader = build_loader([primary_url, secondary_url])
    loader.fetch!

    # The hedge must have fired the secondary (slow primary) and installed its 42.
    poll_until_generation(loader, 42, 4)
    assert_operator secondary_hits.value, :>=, 1,
                    'secondary was never contacted — the hedge did not fire against the slow primary'

    # The slow primary's older 41 lands late and on every subsequent refresh; the
    # reject-older guard must keep the loader on 42.
    3.times { loader.fetch! }
    assert_equal 42, loader.held_generation,
                 'held generation regressed — reject-older must drop the slow 41'
  end

  # o03 heal-forward: the primary is SLOW and serves the NEWER generation (42);
  # the secondary is fast and serves the OLDER generation (41). The hedge seeds
  # readiness off the secondary's 41, then heals forward to the primary's 42 when
  # it lands — reject-older only blocks going backward, never forward.
  #
  # On the pre-hedge sequential fetch! the secondary is never contacted (the slow
  # primary answers first with 42), so secondary_hits == 0 — RED. The hedge
  # contacts the secondary in parallel (GREEN).
  def test_heals_forward_to_slow_newer_primary
    primary_url, = start_upstream(42, delay_s: 1.0)
    secondary_url, secondary_hits = start_upstream(41, delay_s: 0)

    loader = build_loader([primary_url, secondary_url])
    loader.fetch!

    assert_operator secondary_hits.value, :>=, 1,
                    'secondary was never contacted — the hedge did not fire against the slow primary'
    # Heal forward to the slow primary's newer 42.
    poll_until_generation(loader, 42, 4)
  end
end
