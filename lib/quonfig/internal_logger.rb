# frozen_string_literal: true

module Quonfig
  # Internal logger for the Quonfig SDK
  # Uses SemanticLogger if available, falls back to stdlib Logger
  class InternalLogger
    # Optional, host-app-supplied logger. When set (typically via
    # Quonfig::Client.new(logger:)), all InternalLogger instances route
    # writes to it instead of their default backend. Must duck-type as a
    # stdlib Logger (responds to debug/info/warn/error). Missing levels
    # are silently dropped.
    class << self
      attr_accessor :user_logger
    end

    def initialize(klass, logger: nil)
      @klass = klass
      @level_sym = nil # Track the symbol level for consistency
      @injected_logger = logger

      if @injected_logger
        @logger = @injected_logger
        @using_semantic = false
      elsif defined?(SemanticLogger)
        @logger = create_semantic_logger
        @using_semantic = true
      else
        @logger = create_stdlib_logger
        @using_semantic = false
      end

      # Track all instances regardless of logger type
      instances << self
    end

    # Log methods
    def trace(message = nil, event: nil, &block)
      log_message(:trace, message, event: event, &block)
    end

    def debug(message = nil, event: nil, &block)
      log_message(:debug, message, event: event, &block)
    end

    def info(message = nil, event: nil, &block)
      log_message(:info, message, event: event, &block)
    end

    def warn(message = nil, event: nil, &block)
      log_message(:warn, message, event: event, &block)
    end

    def error(message = nil, event: nil, &block)
      log_message(:error, message, event: event, &block)
    end

    def fatal(message = nil, event: nil, &block)
      log_message(:fatal, message, event: event, &block)
    end

    def level
      if @using_semantic
        @logger.level
      else
        # Return the symbol level we tracked, or map from Logger constant
        @level_sym || case @logger.level
                      when Logger::DEBUG then :debug
                      when Logger::INFO then :info
                      when Logger::WARN then :warn
                      when Logger::ERROR then :error
                      when Logger::FATAL then :fatal
                      else :warn
                      end
      end
    end

    def level=(new_level)
      if @using_semantic
        @logger.level = new_level
      else
        # Track the symbol level for consistency
        @level_sym = new_level

        # Map symbol to Logger constant
        next_level = case new_level
                     when :trace, :debug then Logger::DEBUG
                     when :info then Logger::INFO
                     when :warn then Logger::WARN
                     when :error then Logger::ERROR
                     when :fatal then Logger::FATAL
                     else Logger::WARN
                     end

        @logger.level = next_level if @logger.respond_to?(:level=)
      end
    end

    # Our client outputs debug logging,
    # but if you aren't using Quonfig logging this could be too chatty.
    # If you aren't using the quonfig log filter, only log warn level and above
    def self.using_quonfig_log_filter!
      @@instances&.each do |logger|
        logger.level = :trace
      end
    end

    private

    def create_semantic_logger
      default_level = env_log_level || :warn
      logger = SemanticLogger::Logger.new(@klass, default_level)

      # Wrap to prevent recursion
      class << logger
        def log(log, message = nil, progname = nil, &block)
          return if recurse_check[local_log_id]

          recurse_check[local_log_id] = true
          begin
            super
          ensure
            recurse_check[local_log_id] = false
          end
        end

        def local_log_id
          Thread.current.__id__
        end

        private

        def recurse_check
          @recurse_check ||= Concurrent::Map.new(initial_capacity: 2)
        end
      end

      logger
    end

    def create_stdlib_logger
      require 'logger'
      # When using stdlib Logger (no SemanticLogger), write to $stderr only
      # Tests use $logs for SemanticLogger-filtered output, not stdlib Logger
      logger = Logger.new($stderr)

      # When SemanticLogger is not available, default to :warn to match SemanticLogger behavior
      default_level_sym = :warn
      @level_sym = env_log_level || default_level_sym

      logger.level = case @level_sym
                     when :trace, :debug then Logger::DEBUG
                     when :info then Logger::INFO
                     when :warn then Logger::WARN
                     when :error then Logger::ERROR
                     when :fatal then Logger::FATAL
                     else Logger::WARN
                     end
      logger.progname = @klass.to_s

      # Use a custom formatter that mimics SemanticLogger format
      # SemanticLogger format: "ClassName -- Message"
      # This helps tests that expect SemanticLogger-style output
      logger.formatter = proc do |_severity, _datetime, progname, msg|
        "#{progname} -- #{msg}\n"
      end

      logger
    end

    def env_log_level
      level_str = ENV.fetch('QUONFIG_LOG_CLIENT_BOOTSTRAP_LOG_LEVEL', nil)
      level_str&.downcase&.to_sym
    end

    # +event+ (e.g. 'quonfig.init.failed') is a structured field: SemanticLogger
    # gets it as the payload ({ event: ... }); plain Logger-shaped sinks only
    # get the message, which already carries the full line.
    def log_message(level, message, event: nil, &block)
      override = Quonfig::InternalLogger.user_logger
      if override
        write_to_user_logger(override, level, message, &block)
        return
      end

      if @using_semantic
        if event
          @logger.send(level, message, { event: event }, &block)
        else
          @logger.send(level, message, &block)
        end
      else
        # stdlib Logger doesn't have trace
        level = :debug if level == :trace
        return unless @logger.respond_to?(level)

        @logger.send(level, message || block&.call)
      end
    end

    # Route a message to a host-app-supplied logger that duck-types as a
    # stdlib Logger. Missing levels degrade gracefully (trace -> debug;
    # otherwise a no-op). The class name is prepended to keep parity with
    # the SemanticLogger / stdlib formatter output.
    def write_to_user_logger(target, level, message, &block)
      level = :debug if level == :trace && !target.respond_to?(:trace)
      return unless target.respond_to?(level)

      msg = message || block&.call
      target.public_send(level, "#{@klass} -- #{msg}")
    end

    def instances
      @@instances ||= []
    end
  end
end
