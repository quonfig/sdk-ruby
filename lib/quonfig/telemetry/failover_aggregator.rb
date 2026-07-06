# frozen_string_literal: true

module Quonfig
  module Telemetry
    # Accumulates failover-behavior counters over a flush window: how many times
    # the config-fetch hedge fired its secondary leg, how many installs the
    # reject-older ordering guard dropped, and which upstream leg served each
    # successful HTTP install. Every counter is additive and carries NO user
    # data.
    #
    # The aggregator is independently thread-safe (its own mutex) and is written
    # directly from the failover call sites in ConfigLoader rather than through
    # any queue — the call rate is per-config-refresh, not per-evaluation, so a
    # plain mutex has negligible overhead.
    #
    # Wire shape matches sdk-go's FailoverEvent (the canonical reference) and
    # api-telemetry's failover schema EXACTLY — camelCase keys, unix-millis
    # window. #drain_event returns +nil+ when every counter is zero, so a healthy
    # steady-state client emits no failover event at all.
    #
    #   { "failover": {
    #       "start": <int ms>, "end": <int ms>,
    #       "hedgeFired": <int>, "guardRejected": <int>,
    #       "resolvedFromPrimary": <int>, "resolvedFromSecondary": <int>,
    #       "resolvedFromLkg": <int>
    #   } }
    class FailoverAggregator
      def initialize
        @mutex = Mutex.new
        @start_at_ms = nil
        @hedge_fired = 0
        @guard_rejected = 0
        @resolved_from_primary = 0
        @resolved_from_secondary = 0
        # Reserved for a future last-known-good delivery path; backends emit 0.
        @resolved_from_lkg = 0
      end

      # Count one config-fetch cycle whose hedge fired the secondary leg (the
      # primary was slow past the hedge delay or errored fast).
      def record_hedge_fired
        @mutex.synchronize do
          @start_at_ms ||= Quonfig::TimeHelpers.now_in_ms
          @hedge_fired += 1
        end
      end

      # Count one install dropped by the reject-older ordering guard (an
      # equal-or-older snapshot on any install path — HTTP config-fetch or SSE).
      def record_guard_rejected
        @mutex.synchronize do
          @start_at_ms ||= Quonfig::TimeHelpers.now_in_ms
          @guard_rejected += 1
        end
      end

      # Count one successful HTTP install by the leg that served it: source_index
      # 0 is the primary, any index > 0 is a failover/secondary leg. A nil or
      # negative index (SSE / datadir install with no HTTP leg) is ignored.
      def record_resolved_from(source_index)
        return if source_index.nil? || source_index.negative?

        @mutex.synchronize do
          @start_at_ms ||= Quonfig::TimeHelpers.now_in_ms
          if source_index.zero?
            @resolved_from_primary += 1
          else
            @resolved_from_secondary += 1
          end
        end
      end

      # Return the window's counters as a telemetry event hash and reset state.
      # Returns +nil+ when no failover activity occurred (every counter zero).
      def drain_event
        @mutex.synchronize do
          if @hedge_fired.zero? && @guard_rejected.zero? &&
             @resolved_from_primary.zero? && @resolved_from_secondary.zero? &&
             @resolved_from_lkg.zero?
            return nil
          end

          event = {
            'failover' => {
              'start' => @start_at_ms || Quonfig::TimeHelpers.now_in_ms,
              'end' => Quonfig::TimeHelpers.now_in_ms,
              'hedgeFired' => @hedge_fired,
              'guardRejected' => @guard_rejected,
              'resolvedFromPrimary' => @resolved_from_primary,
              'resolvedFromSecondary' => @resolved_from_secondary,
              'resolvedFromLkg' => @resolved_from_lkg
            }
          }

          reset
          event
        end
      end

      private

      # Caller holds @mutex.
      def reset
        @start_at_ms = nil
        @hedge_fired = 0
        @guard_rejected = 0
        @resolved_from_primary = 0
        @resolved_from_secondary = 0
        @resolved_from_lkg = 0
      end
    end
  end
end
