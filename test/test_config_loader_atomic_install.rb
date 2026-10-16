# frozen_string_literal: true

require 'test_helper'

# qfg-i86q (audit 2026-10-16 M2): an install must be observed atomically by
# each lookup. A flag and the segment it references come from one envelope.
#
# Every envelope below makes flag 'f' true: it is IN_SEG of an ALWAYS_TRUE
# segment, but the segment's key alternates between envelopes ('seg.a' /
# 'seg.b'), so a reader that sees the new flag with the old segment set (or
# the other way round) evaluates false. Filler configs widen the install
# window so a key-by-key install is caught reliably.
class TestConfigLoaderAtomicInstall < Minitest::Test
  FILLER = 2_000
  INSTALLS = 199

  def bool_value(val)
    { 'type' => 'bool', 'value' => val }
  end

  def segment(key)
    { 'id' => "id-#{key}", 'key' => key, 'type' => 'segment', 'valueType' => 'bool',
      'default' => { 'rules' => [{ 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }], 'value' => bool_value(true) }] } }
  end

  def flag(seg_key)
    { 'id' => 'id-f', 'key' => 'f', 'type' => 'feature_flag', 'valueType' => 'bool',
      'default' => { 'rules' => [
        { 'criteria' => [{ 'propertyName' => '', 'operator' => 'IN_SEG',
                           'valueToMatch' => { 'type' => 'string', 'value' => seg_key } }],
          'value' => bool_value(true) },
        { 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }], 'value' => bool_value(false) }
      ] } }
  end

  def envelope(gen)
    seg_key = gen.even? ? 'seg.a' : 'seg.b'
    # The flag sorts first and the segment last, so a key-by-key install
    # publishes the new flag long before its segment.
    configs = [flag(seg_key)]
    FILLER.times { |i| configs << { 'id' => "id-#{i}", 'key' => "filler.#{i}", 'type' => 'config', 'valueType' => 'string', 'default' => { 'rules' => [{ 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }], 'value' => { 'type' => 'string', 'value' => "v#{gen}" } }] } } }
    configs << segment(seg_key)
    Quonfig::ConfigEnvelope.new(
      configs: configs,
      meta: { 'version' => "gen-#{gen}", 'environment' => 'production', 'generation' => gen }
    )
  end

  def test_concurrent_reads_never_see_a_torn_install
    store = Quonfig::ConfigStore.new
    options = Quonfig::Options.new(sdk_key: '1-test-sdk-key', api_urls: ['http://127.0.0.1:1'],
                                   enable_sse: false, fallback_poll_enabled: false)
    loader = Quonfig::ConfigLoader.new(store, options)
    client = Quonfig::Client.new(store: store)
    envelopes = (1..INSTALLS).map { |g| envelope(g) }
    loader.apply_envelope(envelopes.first)
    assert client.enabled?('f'), 'precondition: every envelope makes f true'

    done = Concurrent::AtomicBoolean.new(false)
    reads = 0
    torn = 0
    reader = Thread.new do
      until done.true?
        reads += 1
        torn += 1 unless client.enabled?('f')
      end
    end

    envelopes.drop(1).each { |env| loader.apply_envelope(env) }
    done.make_true
    reader.join

    assert_operator reads, :>, 0
    assert_equal 0, torn, "#{torn} of #{reads} concurrent enabled?('f') reads saw a torn install"
  ensure
    client&.stop
  end
end
