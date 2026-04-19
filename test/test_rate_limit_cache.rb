# frozen_string_literal: true

require 'test_helper'
require 'timecop'

class RateLimitCacheTest < Minitest::Test
  def test_set_and_fresh
    cache = Quonfig::RateLimitCache.new(5)
    cache.set('key')
    assert cache.fresh?('key')
  end

  def test_fresh_with_no_set
    cache = Quonfig::RateLimitCache.new(5)
    refute cache.fresh?('key')
  end

  def test_get_after_expiration
    cache = Quonfig::RateLimitCache.new(5)

    Timecop.freeze(Time.now - 6) do
      cache.set('key')
      assert cache.fresh?('key')
    end

    refute cache.fresh?('key')

    # but the data is still there
    assert cache.data.get('key')
  end

  def test_prune
    cache = Quonfig::RateLimitCache.new(5)

    Timecop.freeze(Time.now - 6) do
      cache.set('key')
      assert cache.fresh?('key')
    end

    cache.prune

    refute cache.fresh?('key')
  end
end
