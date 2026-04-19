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
end
