# frozen_string_literal: true

module Quonfig
  module Errors
    # Raised when datadir mode is engaged but no environment was supplied
    # (neither the `environment:` option nor the QUONFIG_ENVIRONMENT env
    # var is set). Datadir mode requires an explicit environment; without
    # one the loader cannot pick the right environment row from each
    # config's `environments` array.
    class MissingEnvironmentError < Quonfig::Error
      def initialize(message = nil)
        message ||= '[quonfig] Environment required for datadir mode; ' \
                    'set the `environment` option or QUONFIG_ENVIRONMENT env var'
        super(message)
      end
    end
  end
end
