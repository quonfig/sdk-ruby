# frozen_string_literal: true

module Quonfig
  # Internal test seam for the SDK's background waits (qfg-goi1.10.26).
  #
  # Every long background wait goes through here with a kind:
  #   :sse    - SSE reconnect backoff (the unjittered base delay)
  #   :engage - fallback-poller grace after a mid-life SSE drop
  #   :poll   - fallback / polling-mode poll interval
  #   :probe  - auth-failed probe period (rule R3)
  #
  # A hook, when set, sees the REQUESTED seconds and returns the seconds to
  # actually wait. Tests use it to record the requested values and compress
  # time (supervisor-test-contract.md Test 8). It is not a customer option and
  # is nil in production.
  module Waits
    class << self
      attr_accessor :hook

      def duration(kind, seconds)
        h = hook
        h ? h.call(kind, seconds) : seconds
      end

      def sleep(kind, seconds)
        Kernel.sleep(duration(kind, seconds))
      end
    end
  end
end
