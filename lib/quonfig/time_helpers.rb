# frozen_string_literal: true

module Quonfig
  module TimeHelpers
    def self.now_in_ms
      ::Time.now.utc.to_i * 1000
    end
  end
end
