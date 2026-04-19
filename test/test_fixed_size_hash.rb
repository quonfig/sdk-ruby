# frozen_string_literal: true

require 'minitest/autorun'
require 'test_helper'

module Quonfig
  class FixedSizeHashTest < Minitest::Test
    def setup
      @max_size = 3
      @hash = FixedSizeHash.new(@max_size)
    end

    def test_acts_like_a_regular_hash_when_under_max_size
      @hash[:a] = 1
      @hash[:b] = 2

      assert_equal 1, @hash[:a]
      assert_equal 2, @hash[:b]
      assert_equal 2, @hash.size
    end

    def test_enforces_max_size_by_evicting_first_added_item
      @hash[:a] = 1
      @hash[:b] = 2
      @hash[:c] = 3
      assert_equal @max_size, @hash.size

      @hash[:d] = 4
      assert_equal @max_size, @hash.size
      assert_nil @hash[:a]  # First item should be evicted
      assert_equal 4, @hash[:d]
    end

    def test_updating_existing_key_does_not_trigger_eviction
      @hash[:a] = 1
      @hash[:b] = 2
      @hash[:c] = 3

      @hash[:b] = 'new value'  # Update existing key

      assert_equal @max_size, @hash.size
      assert_equal 1, @hash[:a]  # First item should still be present
      assert_equal 'new value', @hash[:b]
      assert_equal 3, @hash[:c]
    end

    def test_handles_nil_values
      @hash[:a] = nil
      @hash[:b] = 2
      @hash[:c] = 3
      @hash[:d] = 4

      assert_nil @hash[:a]  # First item should be evicted
      assert_equal 4, @hash[:d]
    end

    def test_preserves_hash_methods
      @hash[:a] = 1
      @hash[:b] = 2

      assert_equal [:a, :b], @hash.keys
      assert_equal [1, 2], @hash.values
      assert @hash.key?(:a)
      refute @hash.key?(:z)
    end

    def test_handles_string_keys
      @hash['a'] = 1
      @hash['b'] = 2
      @hash['c'] = 3
      @hash['d'] = 4

      assert_nil @hash['a']  # First item should be evicted
      assert_equal 4, @hash['d']
    end

    def test_handles_object_keys
      key1 = Object.new
      key2 = Object.new
      key3 = Object.new
      key4 = Object.new

      @hash[key1] = 1
      @hash[key2] = 2
      @hash[key3] = 3
      @hash[key4] = 4

      assert_nil @hash[key1]  # First item should be evicted
      assert_equal 4, @hash[key4]
    end

    def test_can_be_initialized_empty
      assert_equal 0, @hash.size
    end

    def test_enumerable_methods
      @hash[:a] = 1
      @hash[:b] = 2

      mapped = @hash.map { |k, v| [k, v * 2] }.to_h
      assert_equal({ a: 2, b: 4 }, mapped)

      filtered = @hash.select { |_, v| v > 1 }
      assert_equal({ b: 2 }, filtered.to_h)
    end

    def test_clear_maintains_max_size_constraint
      @hash[:a] = 1
      @hash[:b] = 2
      @hash.clear

      assert_equal 0, @hash.size

      # Should still enforce max size after clear
      (@max_size + 1).times { |i| @hash[i] = i }
      assert_equal @max_size, @hash.size
    end
  end
end