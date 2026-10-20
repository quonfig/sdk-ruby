# frozen_string_literal: true

module Quonfig
  module Errors
    # The init-failure error for a hang: an attempt was still in flight when
    # init_timeout_ms ran out. A subclass of InitializationError (reason
    # +:timeout+), so rescuing either class catches it.
    class InitializationTimeoutError < InitializationError
      # +timeout_sec+ and +key+ keep the original positional signature.
      def initialize(timeout_sec, key = nil, message: nil, errors: nil)
        message ||= "Quonfig couldn't initialize in #{timeout_sec} second timeout."
        message += " Trying to fetch key `#{key}`." if key
        super(message, reason: :timeout, errors: errors)
      end
    end
  end
end
