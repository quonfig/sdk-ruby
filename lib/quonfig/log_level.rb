# frozen_string_literal: true

module Quonfig
  # Public LogLevel enum that maps to the underlying Prefab.Config.LogLevel
  module LogLevel
    TRACE = :trace
    DEBUG = :debug
    INFO = :info
    WARN = :warn
    ERROR = :error
    FATAL = :fatal

    # JSON wire-format symbol map. Will be repopulated with the final JSON
    # log-level enum values in qfg-dk6.5+. Kept as a constant so callers continue
    # to load; unknown inputs fall back to DEBUG.
    WIRE_SYMBOL_TO_LOG_LEVEL = {
      :NOT_SET_LOG_LEVEL => DEBUG,
      :TRACE => TRACE,
      :DEBUG => DEBUG,
      :INFO => INFO,
      :WARN => WARN,
      :ERROR => ERROR,
      :FATAL => FATAL
    }.freeze

    def self.from_wire(wire_log_level)
      case wire_log_level
      when Symbol
        WIRE_SYMBOL_TO_LOG_LEVEL.fetch(wire_log_level, DEBUG)
      when String
        WIRE_SYMBOL_TO_LOG_LEVEL.fetch(wire_log_level.to_sym, DEBUG)
      else
        DEBUG
      end
    end
  end
end
