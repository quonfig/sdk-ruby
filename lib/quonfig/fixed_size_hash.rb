# frozen_string_literal: true
module Quonfig
  class FixedSizeHash < Hash
    def initialize(max_size)
      @max_size = max_size
      super()
    end

    def []=(key, value)
      shift if size >= @max_size && !key?(key) # Only evict if adding a new key
      super
    end
  end
end
