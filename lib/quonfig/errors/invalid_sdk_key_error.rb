# frozen_string_literal: true

module Quonfig
  module Errors
    class InvalidSdkKeyError < Quonfig::Error
      def initialize(key)
        if key.nil? || key.empty?
          message = 'No SDK key. Set QUONFIG_BACKEND_SDK_KEY env var or use QUONFIG_DATAFILE'

          super(message)
        else
          message = "Your SDK key format is invalid. Expecting something like 123-development-yourapikey-SDK. You provided `#{key}`"

          super(message)
        end
      end
    end
  end
end
