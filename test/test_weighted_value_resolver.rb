# frozen_string_literal: true

require 'test_helper'

class TestWeightedValueResolver < Minitest::Test
  KEY = 'config_key'

  def test_resolving_single_value
    values = weighted_values([['abc', 1]])
    resolver = Quonfig::WeightedValueResolver.new(values, KEY, nil)
    assert_equal 'abc', resolver.resolve[0].value.string
    assert_equal 0, resolver.resolve[1]
  end

  def test_resolving_multiple_values_evenly_distributed
    values = weighted_values([['abc', 1], ['def', 1]])

    resolver = Quonfig::WeightedValueResolver.new(values, KEY, 'user:001')
    assert_equal 'abc', resolver.resolve[0].value.string
    assert_equal 0, resolver.resolve[1]

    resolver = Quonfig::WeightedValueResolver.new(values, KEY, 'user:456')
    assert_equal 'def', resolver.resolve[0].value.string
    assert_equal 1, resolver.resolve[1]
  end

  def test_resolving_multiple_values_unevenly_distributed
    values = weighted_values([['abc', 1], ['def', 98], ['ghi', 1]])

    resolver = Quonfig::WeightedValueResolver.new(values, KEY, 'user:456')
    assert_equal 'def', resolver.resolve[0].value.string
    assert_equal 1, resolver.resolve[1]

    resolver = Quonfig::WeightedValueResolver.new(values, KEY, 'user:103')
    assert_equal 'ghi', resolver.resolve[0].value.string
    assert_equal 2, resolver.resolve[1]

    resolver = Quonfig::WeightedValueResolver.new(values, KEY, 'user:119')
    assert_equal 'abc', resolver.resolve[0].value.string
    assert_equal 0, resolver.resolve[1]
  end

  def test_resolving_multiple_values_with_simulation
    values = weighted_values([['abc', 1], ['def', 98], ['ghi', 1]])
    results = {}

    10_000.times do |i|
      result = Quonfig::WeightedValueResolver.new(values, KEY, "user:#{i}").resolve[0].value.string
      results[result] ||= 0
      results[result] += 1
    end

    assert_in_delta 100, results['abc'], 20
    assert_in_delta 9800, results['def'], 50
    assert_in_delta 100, results['ghi'], 20
  end

  private

  def weighted_values(values_and_weights)
    values_and_weights.map do |value, weight|
      weighted_value(value, weight)
    end
  end

  def weighted_value(string, weight)
    PrefabProto::WeightedValue.new(
      value: PrefabProto::ConfigValue.new(string: string), weight: weight
    )
  end
end
