# frozen_string_literal: true

module Quonfig
  module Errors
    # Raised when the requested environment (via `environment:` option or
    # QUONFIG_ENVIRONMENT) isn't listed in the workspace's `quonfig.json`.
    # Catches typos like `"prdoduction"` early instead of silently
    # evaluating against default rules.
    class InvalidEnvironmentError < Quonfig::Error
      def initialize(environment, available = nil)
        message = "[quonfig] Environment \"#{environment}\" not found in workspace"
        if available && !Array(available).empty?
          message += "; available environments: #{Array(available).join(', ')}"
        end
        super(message)
      end
    end
  end
end
