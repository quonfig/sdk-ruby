# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

# qfg-9dxb.8 (decided 2026-09-28): a weighted rollout whose hashByPropertyName
# is missing from the evaluation context serves the FIRST weighted variant
# (fraction 0.0), not a per-call random one. Reason stays SPLIT, details
# flag_metadata gains 'hashPropertyMissing' => true only when this fallback
# fires, and the SDK logs one WARN per config key per client.
#
# Fixture: feature-flag.weighted hashes on user.tracking_id; variants are
# 1 (weight 1000), 3 (2000), 2 (97000). A random bucket lands on 1 ~1% of
# the time, so 50 repeats rule out luck.
class TestWeightedHashPropertyMissing < Minitest::Test
  KEY = 'feature-flag.weighted'
  FIXTURE_DIR = File.expand_path('../../integration-test-data/data/integration-tests', __dir__)
  WARN_TEXT = 'quonfig: weighted rollout for "feature-flag.weighted" hashes on "user.tracking_id" ' \
              'which is missing from context; using first variant'

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

  def test_missing_property_serves_first_variant_every_time
    client = fixture_client
    capture_warns do
      50.times do
        assert_equal 1, client.get(KEY, nil, { user: { key: 'no-tracking-id-user' } })
      end
    end
  end

  def test_no_context_serves_first_variant_every_time
    client = fixture_client
    capture_warns do
      50.times { assert_equal 1, client.get(KEY) }
    end
  end

  def test_nil_property_value_is_treated_as_missing
    client = fixture_client
    capture_warns do
      50.times { assert_equal 1, client.get(KEY, nil, { user: { tracking_id: nil } }) }
    end
  end

  def test_details_flag_hash_property_missing_and_reason_stays_split
    client = fixture_client
    capture_warns do
      details = client.get_int_details(KEY, context: { user: { key: 'x' } })
      assert_equal 1, details.value
      assert_equal Quonfig::EvaluationDetails::REASON_SPLIT, details.reason
      assert_nil details.error_code
      assert_equal true, details.flag_metadata['hashPropertyMissing']
      assert_equal 0, details.flag_metadata['weighted_value_index']
    end
  end

  def test_details_omit_hash_property_missing_when_property_present
    client = fixture_client
    details = client.get_int_details(KEY, context: { user: { tracking_id: 'u71' } })
    assert_equal 3, details.value
    assert_equal Quonfig::EvaluationDetails::REASON_SPLIT, details.reason
    refute details.flag_metadata.key?('hashPropertyMissing')
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

  def test_weighted_value_resolver_nil_hash_value_picks_first_variant
    values = [{ 'weight' => 1, 'value' => 'a' }, { 'weight' => 99, 'value' => 'b' }]
    50.times do
      variant, index = Quonfig::WeightedValueResolver.new(values, 'k', nil).resolve
      assert_equal 'a', variant['value']
      assert_equal 0, index
    end
  end
end
