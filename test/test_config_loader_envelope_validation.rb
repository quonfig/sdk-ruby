# frozen_string_literal: true

require 'test_helper'
require 'json'

# qfg-9dxb.3 (audit H2, cross-SDK). Two gaps in the network install path:
#
# Fix B — a 200 whose body is not a config envelope (`{}`, `{"error":"x"}` —
# a misbehaving proxy or WAF) used to parse as "zero configs" and install,
# wiping every key on an established client. A payload must carry a `meta`
# object with a non-empty `version` (api-delivery and `qfg serve` always send
# one). On HTTP a failed check is a leg error (hedge/failover proceed, the ETag
# is not stored); on SSE the event is dropped like malformed JSON.
#
# Fix A — an UNVERSIONED install (generation <= 0/absent) must never LOWER a
# positive held generation. qfg-9dxb.9 narrowed this further: once a real
# generation is held, an unversioned payload does not install at all.
class TestConfigLoaderEnvelopeValidation < Minitest::Test
  PRIMARY = 'https://primary.example.test'
  SECONDARY = 'https://secondary.example.test'

  # Fake HttpConnection: each URL maps to a queue of [status, body, etag].
  class FakeConn
    def initialize(responses, log)
      @responses = responses
      @log = log
    end

    def get(_path, headers)
      @log << headers.dup
      status, body, etag = @responses.length > 1 ? @responses.shift : @responses.first
      Faraday::Response.new(status: status, body: body,
                            response_headers: etag ? { 'ETag' => etag } : {})
    end
  end

  def config(key)
    { 'id' => "id-#{key}", 'key' => key, 'type' => 'config',
      'valueType' => 'bool', 'default' => { 'rules' => [] } }
  end

  def envelope_body(gen: 7, version: 'v7', keys: %w[a.flag b.flag])
    meta = { 'version' => version, 'environment' => 'production' }
    meta['generation'] = gen unless gen.nil?
    JSON.generate('configs' => keys.map { |k| config(k) }, 'meta' => meta)
  end

  def build_loader(urls)
    options = Quonfig::Options.new(
      sdk_key: '1-test-sdk-key', api_urls: urls,
      enable_sse: false, fallback_poll_enabled: false,
      config_fetch_hedge_delay_ms: 5_000
    )
    @store = Quonfig::ConfigStore.new
    Quonfig::ConfigLoader.new(@store, options)
  end

  # Runs the block with HttpConnection.new returning a FakeConn per URL.
  def with_upstreams(map)
    headers_log = Hash.new { |h, k| h[k] = [] }
    conns = map.to_h { |url, responses| [url, FakeConn.new(responses.dup, headers_log[url])] }
    Quonfig::HttpConnection.stub :new, ->(uri, _key, **_kw) { conns.fetch(uri) } do
      yield headers_log
    end
  end

  %w[{} {"error":"x"}].each_with_index do |junk, i|
    define_method("test_junk_200_#{i}_does_not_wipe_established_client") do
      loader = build_loader([PRIMARY])
      with_upstreams(PRIMARY => [[200, envelope_body, '"good"'], [200, junk, '"junk"']]) do |headers|
        assert_equal :updated, loader.fetch!
        assert_equal 7, loader.held_generation

        assert_equal :failed, loader.fetch!, 'a non-envelope 200 is a leg error'
        assert_equal 7, loader.held_generation, 'held generation must not be lowered'
        assert_equal %w[a.flag b.flag], @store.keys.sort, 'keys must not be wiped'
        assert_equal '"good"', loader.etag, 'junk ETag must not be stored'
        assert_equal '"good"', headers[PRIMARY][1]['If-None-Match']
      end
      assert_logged([/non-envelope/])
    end
  end

  def test_meta_without_version_is_rejected
    loader = build_loader([PRIMARY])
    body = JSON.generate('configs' => [], 'meta' => { 'environment' => 'production' })
    with_upstreams(PRIMARY => [[200, envelope_body, nil], [200, body, nil]]) do
      loader.fetch!
      assert_equal :failed, loader.fetch!
      assert_equal %w[a.flag b.flag], @store.keys.sort
    end
    assert_logged([/non-envelope/])
  end

  def test_junk_primary_hedges_to_secondary
    loader = build_loader([PRIMARY, SECONDARY])
    with_upstreams(PRIMARY => [[200, '{}', '"junk"']],
                   SECONDARY => [[200, envelope_body(gen: 9), '"sec"']]) do
      assert_equal :updated, loader.fetch!
      assert_equal 9, loader.held_generation
      assert_equal 'secondary', loader.resolved_from
      assert_nil loader.etag, 'primary junk ETag must not be stored'
    end
    assert_logged([/non-envelope/])
  end

  def sse_envelope(gen, keys)
    meta = { 'version' => "v#{gen}", 'environment' => 'production' }
    meta['generation'] = gen unless gen.nil?
    Quonfig::ConfigEnvelope.new(configs: keys.map { |k| config(k) }, meta: meta)
  end

  # qfg-9dxb.9: gen 0 now only comes from a server whose git store is damaged
  # (rev-count failed). It must not override a held real generation: hold gen N
  # with NEW content, receive gen 0 with OLD content -> still NEW; the healthy
  # gen N re-delivery afterwards is a same-generation no-op -> still NEW.
  def test_gen0_old_content_does_not_override_held_generation
    loader = build_loader([PRIMARY])
    refute_equal :not_modified, loader.apply_envelope(sse_envelope(12, %w[new.flag]))
    assert_equal 1, loader.install_count

    assert_equal :not_modified, loader.apply_envelope(sse_envelope(0, %w[old.flag]))
    assert_equal %w[new.flag], @store.keys, 'gen 0 (OLD) must not replace held gen 12 (NEW)'
    assert_equal 12, loader.held_generation
    assert_equal 1, loader.install_count

    assert_equal :not_modified, loader.apply_envelope(sse_envelope(12, %w[new.flag]))
    assert_equal %w[new.flag], @store.keys, 'gen 12 re-delivery must leave NEW in place'
    assert_equal 12, loader.held_generation
    assert_equal 1, loader.install_count
  end

  # qfg serve sends version + environment but no generation (absent -> 0): an
  # established client holding a real generation does not install it.
  def test_qfg_serve_payload_without_generation_does_not_override_held_generation
    loader = build_loader([PRIMARY])
    with_upstreams(PRIMARY => [[200, envelope_body(gen: 7), '"one"'],
                               [200, envelope_body(gen: nil, version: 'serve', keys: %w[c.flag]), '"two"']]) do
      loader.fetch!
      assert_equal :not_modified, loader.fetch!
      assert_equal %w[a.flag b.flag], @store.keys.sort, 'unversioned payload must not replace held gen 7'
      assert_equal 1, loader.install_count
      assert_equal 7, loader.held_generation
    end
  end

  def test_fresh_client_seeds_from_unversioned_payload
    loader = build_loader([PRIMARY])
    with_upstreams(PRIMARY => [[200, envelope_body(gen: nil, version: 'serve'), nil]]) do
      assert_equal :updated, loader.fetch!
      assert_equal 0, loader.held_generation
    end
  end

  # qfg-9dxb.9: a client that has only ever seen gen 0 (e.g. `qfg serve`)
  # keeps installing every gen 0 payload -- it never held a real generation.
  def test_gen0_only_client_installs_each_gen0_payload
    loader = build_loader([PRIMARY])
    refute_equal :not_modified, loader.apply_envelope(sse_envelope(0, %w[one.flag]))
    refute_equal :not_modified, loader.apply_envelope(sse_envelope(0, %w[two.flag]))
    refute_equal :not_modified, loader.apply_envelope(sse_envelope(nil, %w[three.flag]))
    assert_equal %w[three.flag], @store.keys
    assert_equal 3, loader.install_count
    assert_equal 0, loader.held_generation

    # And a real generation still heals forward from there.
    refute_equal :not_modified, loader.apply_envelope(sse_envelope(5, %w[real.flag]))
    assert_equal 5, loader.held_generation
    assert_equal %w[real.flag], @store.keys
  end
end
