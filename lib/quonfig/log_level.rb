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

    # Map from PrefabProto::LogLevel enum symbols (uppercase) to our public LogLevel constants (lowercase)
    # When unwrapped, the proto returns uppercase symbols like :INFO, :DEBUG, etc.
    PROTO_SYMBOL_TO_LOG_LEVEL = {
      :NOT_SET_LOG_LEVEL => DEBUG,
      :TRACE => TRACE,
      :DEBUG => DEBUG,
      :INFO => INFO,
      :WARN => WARN,
      :ERROR => ERROR,
      :FATAL => FATAL
    }.freeze

    # Map from PrefabProto::LogLevel enum integer values to our public LogLevel constants
    PROTO_INT_TO_LOG_LEVEL = {
      PrefabProto::LogLevel::NOT_SET_LOG_LEVEL => DEBUG,
      PrefabProto::LogLevel::TRACE => TRACE,
      PrefabProto::LogLevel::DEBUG => DEBUG,
      PrefabProto::LogLevel::INFO => INFO,
      PrefabProto::LogLevel::WARN => WARN,
      PrefabProto::LogLevel::ERROR => ERROR,
      PrefabProto::LogLevel::FATAL => FATAL
    }.freeze

    def self.from_proto(proto_log_level)
      case proto_log_level
      when Symbol
        PROTO_SYMBOL_TO_LOG_LEVEL.fetch(proto_log_level, DEBUG)
      when Integer
        PROTO_INT_TO_LOG_LEVEL.fetch(proto_log_level, DEBUG)
      else
        DEBUG
      end
    end
  end
end
