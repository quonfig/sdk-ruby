# frozen_string_literal: true

module Quonfig
  class WeightedValueResolver
    MAX_32_FLOAT = 4_294_967_294.0

    def initialize(weights, config_key, context_hash_value)
      @weights = weights
      @config_key = config_key
      @context_hash_value = context_hash_value
    end

    def resolve
      percent = @context_hash_value ? user_percent : rand

      index = variant_index(percent)

      [@weights[index], index]
    end

    def user_percent
      to_hash = "#{@config_key}#{@context_hash_value}"
      int_value = Murmur3.murmur3_32(to_hash)
      int_value / MAX_32_FLOAT
    end

    def variant_index(percent_through_distribution)
      distribution_space = @weights.inject(0) { |sum, v| sum + v.weight }
      bucket = distribution_space * percent_through_distribution

      sum = 0
      @weights.each_with_index do |variant_weight, index|
        return index if bucket < sum + variant_weight.weight

        sum += variant_weight.weight
      end

      # In the event that all weights are zero, return the last variant
      @weights.size - 1
    end
  end
end
