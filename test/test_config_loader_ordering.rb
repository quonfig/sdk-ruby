# frozen_string_literal: true

require 'test_helper'
require 'webrick'
require 'socket'
require 'json'

# Reject-older install guard (qfg-7h5d.1.9) — the unit-level analogue of chaos
# scenarios o02 (secondary-older), o03 (late-primary-heals), and o04
# (same-gen-noop). Canonical ordering: install only if
# incoming.Meta.generation > held; a fresh client seeds off whatever arrives
# first; same-generation is a no-op (no flap).
#
# RED until install_envelope grows the guard: without it every install is
# unconditional, so a failover to the OLDER secondary regresses the held
# generation and a duplicate same-gen leg re-installs.
class TestConfigLoaderOrdering < Minitest::Test
  PRIMARY_PORT   = 18_571
  SECONDARY_PORT = 18_572
  SINGLE_PORT    = 18_573

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
    { 'id' => "c-#{gen}", 'key' => 'ordering.flag', 'type' => 'config',
      'valueType' => 'bool', 'default' => { 'rules' => [] } }
  end

  def envelope_json(gen)
    JSON.generate(
      'configs' => [config_for(gen)],
      'meta' => { 'version' => "gen-#{gen}", 'environment' => 'production', 'generation' => gen }
    )
  end

  # gen_proc returns the current generation int; dead_proc returns whether the
  # server should refuse (503). Each generation gets a distinct ETag so a bumped
  # generation isn't masked as a 304 by the loader's shared If-None-Match.
  def start_server(port, gen_proc, dead_proc: -> { false })
    log = WEBrick::Log.new(StringIO.new)
    server = WEBrick::HTTPServer.new(Port: port, Logger: log, AccessLog: [])
    server.mount_proc '/api/v2/configs' do |_req, res|
      if dead_proc.call
        res.status = 503
        res.body = 'primary refused'
        next
      end
      g = gen_proc.call
      res.status = 200
      res['Content-Type'] = 'application/json'
      res['ETag'] = "gen-#{g}"
      res.body = envelope_json(g)
    end
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

  def build_loader(urls)
    options = Quonfig::Options.new(
      sdk_key: '1-test-sdk-key', api_urls: urls,
      enable_sse: false, fallback_poll_enabled: false
    )
    Quonfig::ConfigLoader.new(Quonfig::ConfigStore.new, options)
  end

  # o02: an established client (on the newer primary) must never regress to the
  # older secondary when it fails over.
  def test_failover_to_older_secondary_does_not_regress
    primary_dead = false
    primary_url   = start_server(PRIMARY_PORT, -> { 42 }, dead_proc: -> { primary_dead })
    secondary_url = start_server(SECONDARY_PORT, -> { 41 })

    loader = build_loader([primary_url, secondary_url])

    assert_equal :updated, loader.fetch!
    assert_equal 42, loader.held_generation, 'must establish on the primary (gen 42)'
    assert_equal 'primary', loader.resolved_from

    # Primary goes dark; every refresh now fails over to the secondary's OLDER 41.
    primary_dead = true
    5.times { loader.fetch! }

    assert_equal 42, loader.held_generation,
                 'reject-older guard must drop the secondary gen 41 and keep the established 42'
  end

  # o03 + o04: a fresh client seeds off whatever arrives first, a same-generation
  # refresh is a no-op (no second install), and a newer generation heals forward.
  def test_seed_then_same_gen_noop_then_heal_forward
    current_gen = 41
    url = start_server(SINGLE_PORT, -> { current_gen })

    loader = build_loader([url])

    assert_equal :updated, loader.fetch!
    assert_equal 41, loader.held_generation, 'fresh client seeds off gen 41'
    seed_installs = loader.install_count
    assert_equal 1, seed_installs

    # Same generation served again: no-op, no second install (o04).
    3.times { loader.fetch! }
    assert_equal seed_installs, loader.install_count,
                 'same-generation refresh must not re-install (would flap an established client)'
    assert_equal 41, loader.held_generation

    # A newer generation lands: heal forward to 42 (o03).
    current_gen = 42
    loader.fetch!
    assert_equal 42, loader.held_generation, 'newer generation must heal forward'
    assert_equal seed_installs + 1, loader.install_count
  end
end
