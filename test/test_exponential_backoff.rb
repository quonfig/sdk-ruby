# frozen_string_literal: true

require 'test_helper'

class TestExponentialBackoff < Minitest::Test
  def test_backoff
    backoff = Quonfig::ExponentialBackoff.new(max_delay: 120)

    assert_equal 2, backoff.call
    assert_equal 4, backoff.call
    assert_equal 8, backoff.call
    assert_equal 16, backoff.call
    assert_equal 32, backoff.call
    assert_equal 64, backoff.call
    assert_equal 120, backoff.call
    assert_equal 120, backoff.call
  end

  def test_backoff_with_15x_multiplier_matches_quonfig_spec
    # Spec: initial 8s, multiplier 1.5, max 600s (matches sdk-node reporter.ts)
    backoff = Quonfig::ExponentialBackoff.new(
      initial_delay: 8, max_delay: 600, multiplier: 1.5
    )

    assert_equal 8, backoff.call
    assert_equal 12.0, backoff.call
    assert_equal 18.0, backoff.call
    assert_equal 27.0, backoff.call
    assert_equal 40.5, backoff.call
    assert_equal 60.75, backoff.call
  end

  def test_periodic_sync_default_matches_quonfig_spec
    mod = Class.new { include Quonfig::PeriodicSync }.new
    interval = mod.send(:calculate_sync_interval, nil)

    # Spec: initial 8s, multiplier 1.5, max 600s
    assert_equal 8, interval.call
    assert_equal 12.0, interval.call
    assert_equal 18.0, interval.call
    assert_equal 27.0, interval.call
    assert_equal 40.5, interval.call
  end
end
