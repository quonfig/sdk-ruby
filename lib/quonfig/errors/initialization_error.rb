# frozen_string_literal: true

module Quonfig
  module Errors
    # Raised by Client.new under on_init_failure: :fail (the default) when no
    # config could be loaded (qfg-9p4i.10; init-failure design B.4). The base
    # of the init-failure family: rescue this to catch every init failure.
    #
    # +reason+ is one of:
    # - +:unavailable+ - every attempt failed fast (refused, DNS, 5xx) until
    #   init_timeout_ms ran out
    # - +:unauthorized+ - every delivery leg rejected the SDK key (401/403);
    #   raised at once, without waiting out the timeout
    # - +:timeout+ - an attempt was still in flight at init_timeout_ms
    #   (InitializationTimeoutError)
    #
    # +errors+ is the per-leg summary (+primary=<host>: <error>; ...+). It names
    # hosts only, never the SDK key.
    class InitializationError < Quonfig::Error
      REASONS = %i[unavailable unauthorized timeout].freeze

      attr_reader :reason, :errors

      def initialize(message = 'Quonfig failed to initialize', reason: :unavailable, errors: nil)
        @reason = reason
        @errors = errors
        super(message)
      end
    end
  end
end
