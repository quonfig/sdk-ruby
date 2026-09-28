# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

# qfg-9dxb.8 (revised 2026-09-28): when a weighted rollout's
# hashByPropertyName is set but the value is missing from the context (no
# context, named context absent, property absent, or nil), the SDK hashes
# configKey + "" exactly as for a present empty string, then walks the
# weights as normal. Missing and empty give the same bucket. Reason stays
# SPLIT; details flag_metadata gains 'hashPropertyMissing' => true only when
# the value is missing, and the SDK logs one WARN per config key per client.
#
# With NO hashByPropertyName (unset or empty) the rollout still picks a
# random variant on every evaluation, exactly as in v1.5.0.
class TestWeightedHashPropertyMissing < Minitest::Test
  KEY = 'feature-flag.weighted'
  FIXTURE_DIR = File.expand_path('../../integration-test-data/data/integration-tests', __dir__)
  WARN_TEXT = 'quonfig: weighted rollout for "feature-flag.weighted" hashes on "user.tracking_id" ' \
              'which is missing from context; hashing an empty value instead'

  # Variant released v1.5.0 serves for a present empty tracking_id
  # (computed on `git archive v1.5.0`).
  V150_EMPTY_VALUE = 2

  # (user.tracking_id => variant) computed on the released v1.5.0 code
  # (git archive v1.5.0). A present hash property must keep bucketing
  # bit-for-bit identically.
  PINNED_V150 = {
    'user:1' => 2,
    'abc' => 2,
    '42' => 2,
    'u35' => 1,
    'u69' => 1,
    'u71' => 3,
    'u83' => 3,
    '' => 2
  }.freeze

  MISSING_CONTEXTS = [
    nil,                              # no context at all
    {},                               # empty context
    { team: { key: 't1' } },          # named context absent
    { user: { key: 'no-tracking' } }, # property absent
    { user: { tracking_id: nil } }    # nil value
  ].freeze

  def fixture_client
    skip "integration-test-data sibling missing at #{FIXTURE_DIR}" unless Dir.exist?(FIXTURE_DIR)

    Quonfig::Client.new(
      Quonfig::Options.new(datadir: FIXTURE_DIR, environment: 'Production',
                           enable_sse: false, enable_polling: false)
    )
  end

  # Capture Resolver WARNs without touching the global logger config.
  def capture_warns(&block)
    warns = []
    Quonfig::Resolver::LOG.stub(:warn, ->(msg = nil, &_) { warns << msg }, &block)
    warns
  end

  def inline_client(key, weights, hash_property)
    wv = {
      'weightedValues' => weights.each_with_index.map do |w, i|
        { 'value' => { 'type' => 'string', 'value' => "v#{i}" }, 'weight' => w }
      end
    }
    wv['hashByPropertyName'] = hash_property unless hash_property.nil?
    config = {
      'id' => "cid-#{key}", 'key' => key, 'type' => 'feature_flag',
      'valueType' => 'string', 'sendToClientSdk' => false, 'environment' => nil,
      'default' => { 'rules' => [{ 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
                                   'value' => { 'type' => 'weighted_values', 'value' => wv } }] }
    }
    store = Quonfig::ConfigStore.new
    store.set(key, config)
    Quonfig::Client.new(Quonfig::Options.new, store: store)
  end

  def test_missing_and_empty_serve_the_v150_empty_value
    client = fixture_client
    capture_warns do
      assert_equal V150_EMPTY_VALUE, client.get(KEY, nil, { user: { tracking_id: '' } })
      MISSING_CONTEXTS.each do |ctx|
        20.times do
          assert_equal V150_EMPTY_VALUE, client.get(KEY, nil, ctx), "ctx=#{ctx.inspect}"
        end
      end
    end
  end

  def test_zero_weight_first_variant_never_served_when_missing
    %w[zero.a zero.b zero.c k1 k2 k3 k4 k5].each do |key|
      client = inline_client(key, [0, 50, 50], 'user.tracking_id')
      capture_warns do
        [nil, { user: { key: 'u' } }, { user: { tracking_id: '' } }].each do |ctx|
          refute_equal 'v0', client.get(key, nil, ctx), "key=#{key} ctx=#{ctx.inspect}"
        end
      end
    end
  end

  def test_no_hash_property_picks_random_variant_every_evaluation
    [nil, ''].each do |hash_property|
      client = inline_client('no-hash', [50, 50], hash_property)
      [nil, { user: { key: 'u1', tracking_id: 't1' } }].each do |ctx|
        warns = capture_warns do
          seen = Array.new(1000) { client.get('no-hash', nil, ctx) }.tally
          assert_equal %w[v0 v1], seen.keys.sort, "hash_property=#{hash_property.inspect} ctx=#{ctx.inspect}"
          details = client.get_string_details('no-hash', context: ctx)
          refute details.flag_metadata.key?('hashPropertyMissing')
        end
        assert_empty warns
      end
    end
  end

  def test_details_flag_hash_property_missing_and_reason_stays_split
    client = fixture_client
    capture_warns do
      MISSING_CONTEXTS.each do |ctx|
        details = client.get_int_details(KEY, context: ctx)
        assert_equal V150_EMPTY_VALUE, details.value
        assert_equal Quonfig::EvaluationDetails::REASON_SPLIT, details.reason
        assert_nil details.error_code
        assert_equal true, details.flag_metadata['hashPropertyMissing'], "ctx=#{ctx.inspect}"
      end
    end
  end

  def test_details_omit_hash_property_missing_when_present_or_empty
    client = fixture_client
    warns = capture_warns do
      { 'u71' => 3, '' => V150_EMPTY_VALUE }.each do |id, expected|
        details = client.get_int_details(KEY, context: { user: { tracking_id: id } })
        assert_equal expected, details.value
        assert_equal Quonfig::EvaluationDetails::REASON_SPLIT, details.reason
        refute details.flag_metadata.key?('hashPropertyMissing')
      end
    end
    assert_empty warns
  end

  def test_warns_exactly_once_per_key_across_many_evaluations
    client = fixture_client
    warns = capture_warns do
      25.times { client.get(KEY, nil, { user: { key: 'a' } }) }
      25.times { client.get(KEY) }
      10.times { client.get_int_details(KEY, context: { user: { key: 'b' } }) }
      5.times { client.get(KEY, nil, { user: { tracking_id: 'u35' } }) }
    end
    assert_equal [WARN_TEXT], warns
  end

  def test_warns_once_per_key_for_each_key
    warns = capture_warns do
      %w[w.one w.two].each do |key|
        client = inline_client(key, [50, 50], 'user.tracking_id')
        3.times { client.get(key) }
      end
    end
    assert_equal 2, warns.size
    assert(warns.any? { |w| w.include?('"w.one"') })
    assert(warns.any? { |w| w.include?('"w.two"') })
  end

  def test_no_warn_when_property_present
    client = fixture_client
    warns = capture_warns do
      PINNED_V150.each_key { |id| client.get(KEY, nil, { user: { tracking_id: id } }) }
    end
    assert_empty warns
  end

  def test_present_property_buckets_match_released_v150
    client = fixture_client
    PINNED_V150.each do |tracking_id, expected|
      assert_equal expected, client.get(KEY, nil, { user: { tracking_id: tracking_id } }),
                   "tracking_id=#{tracking_id.inspect} moved bucket vs v1.5.0"
    end
  end

  # Resolver#resolve_value is public (client.resolver); v1.5.0 called its
  # block with exactly one argument, so a 1-arity lambda must keep working.
  def test_resolve_value_block_is_called_with_one_argument
    client = fixture_client
    config = client.resolver.raw(KEY)
    value = config['environment']['rules'][0]['value']
    assert_equal 'weighted_values', value['type']
    indexes = []
    one_arity = ->(idx) { indexes << idx }
    capture_warns do
      client.resolver.resolve_value(value, config, { user: { tracking_id: 'u71' } }, &one_arity)
      client.resolver.resolve_value(value, config, { user: { key: 'x' } }, &one_arity)
    end
    assert_equal 2, indexes.size
    assert(indexes.all?(Integer))
  end
end
