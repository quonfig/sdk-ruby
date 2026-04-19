# frozen_string_literal: true

module Quonfig
  # This class implements exponential backoff with a maximum delay.
  #
  # This is the default sync interval for aggregators.
  class ExponentialBackoff
    def initialize(max_delay:, initial_delay: 2, multiplier: 2)
      @initial_delay = initial_delay
      @max_delay = max_delay
      @multiplier = multiplier
      @delay = initial_delay
    end

    def call
      delay = @delay
      @delay = [@delay * @multiplier, @max_delay].min
      delay
    end
  end
end
