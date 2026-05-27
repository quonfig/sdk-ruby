# frozen_string_literal: true

# Coordinated scheduling for the cross-SDK chaos harness. Extracted into its
# own file so the cancellation behavior can be unit-tested without booting
# toxiproxy.
#
# Why this matters (qfg-p35y): chaos scenarios are independent Minitest cases
# that share a single toxiproxy instance. If scenario A schedules a "clear
# toxic" event at at_ms=30000 and scenario A's expectations all pass within
# 5s, the chaos expectation loop exits early. A naive sleep-based scheduler
# keeps the clear-thread alive — its deferred `set_enabled('sse', true)`
# then fires DURING scenario B and silently re-enables the SSE proxy that B
# just disabled. That made scenario 05 (SSE down for 180s) flake with
# state='connected' instead of 'falling_back': the leftover clear from
# scenario 07 re-enabled SSE 16s into scenario 05's outage, the Layer 2
# fallback timer's cancellation path then kicked in on the spurious
# :connected edge, and falling_back never engaged within within_ms=135000.

module Quonfig
  module Chaos
    # Cancellable countdown latch. Threads wait via #wait(timeout); calling
    # #set! wakes them up immediately. Used to cancel pending chaos events
    # when a scenario's expectation loop exits early.
    class StopFlag
      def initialize
        @m = Mutex.new
        @c = ConditionVariable.new
        @set = false
      end

      def set?
        @m.synchronize { @set }
      end

      def set!
        @m.synchronize do
          @set = true
          @c.broadcast
        end
      end

      def wait(seconds)
        @m.synchronize do
          return if @set

          @c.wait(@m, seconds)
        end
      end
    end

    # Schedule +block+ to fire +at_ms+ from now, cancelling the firing if
    # +stop_flag+ is set before the delay elapses. Returns the Thread; the
    # caller is responsible for joining (typically with stop_flag.set!
    # called first so the join completes promptly).
    def self.schedule_event(stop_flag, at_ms, &block)
      Thread.new do
        stop_flag.wait(at_ms / 1000.0)
        next if stop_flag.set?

        block.call
      end
    end
  end
end
