# frozen_string_literal: true

# Telemetry transport contract fixture (qfg-y8je.8).
# Monotonic milliseconds that only move when the test says so.
class ManualTelemetryClock
  def initialize(start_ms = 1_000_000)
    @now = start_ms
  end

  def now_ms
    @now
  end

  def advance(ms)
    @now += ms
  end

  def set(ms)
    @now = ms
  end
end
