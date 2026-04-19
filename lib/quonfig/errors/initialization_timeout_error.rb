# frozen_string_literal: true

module Quonfig
  module Errors
    class InitializationTimeoutError < Quonfig::Error
      def initialize(timeout_sec, key)
        message = "Quonfig couldn't initialize in #{timeout_sec} second timeout. Trying to fetch key `#{key}`."
        super(message)
      end
    end
  end
end
