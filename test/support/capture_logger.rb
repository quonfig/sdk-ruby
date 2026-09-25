# frozen_string_literal: true

# Telemetry transport contract fixture (qfg-y8je.8).
# A Logger-shaped sink (the SDK's +logger:+ option) that keeps every line with
# its level, so tests can count log episodes per level.
class CaptureLogger
  def initialize
    @mutex = Mutex.new
    @lines = []
  end

  %i[debug info warn error].each do |level|
    define_method(level) do |msg = nil, &block|
      text = msg || block&.call
      @mutex.synchronize { @lines << [level, text.to_s] }
    end
  end

  def log_count(level, pattern = /.*/)
    @mutex.synchronize { @lines.count { |lvl, text| lvl == level && text.match?(pattern) } }
  end

  def lines(level = nil)
    @mutex.synchronize { level ? @lines.select { |lvl, _| lvl == level } : @lines.dup }
  end

  def clear
    @mutex.synchronize { @lines.clear }
  end
end
