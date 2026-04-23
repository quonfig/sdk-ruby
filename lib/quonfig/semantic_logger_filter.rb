# frozen_string_literal: true

module Quonfig
  # SemanticLogger filter that gates log output by a single Quonfig config
  # whose rules target the logger via the
  # +quonfig-sdk-logging.key+ context property.
  #
  # Usage:
  #   filter = client.semantic_logger_filter(config_key: 'log-level.my-app')
  #   SemanticLogger.add_appender(io: $stdout, filter: filter)
  #
  # The filter exposes the SemanticLogger logger name (which is typically the
  # native Ruby class name, e.g. +"MyApp::Services::Auth"+) under the
  # +quonfig-sdk-logging+ named context with property +key+ so customer rules
  # can discriminate per-logger via PROP_STARTS_WITH_ONE_OF /
  # PROP_IS_ONE_OF etc. Lookup is O(1): one +client.get+ call per log line.
  #
  # Logger names are passed through verbatim — there is no snake_case
  # normalization. Matching rules should target the exact class name
  # (e.g. +MyApp::+, +MyApp::Services::Auth+).
  #
  # The constants +LOGGER_CONTEXT_NAME+ and +LOGGER_CONTEXT_KEY_PROP+ are
  # load-bearing: they match +QUONFIG_SDK_LOGGING_CONTEXT_NAME+ in sdk-node
  # and sdk-go, and are consumed by api-telemetry's example-context
  # auto-capture. Do not rename in isolation.
  class SemanticLoggerFilter
    LEVELS = {
      trace: 0,
      debug: 1,
      info:  2,
      warn:  3,
      error: 4,
      fatal: 5
    }.freeze

    LOGGER_CONTEXT_NAME     = 'quonfig-sdk-logging'
    LOGGER_CONTEXT_KEY_PROP = 'key'

    def self.semantic_logger_loaded?
      defined?(SemanticLogger)
    end

    def initialize(client, config_key:)
      unless self.class.semantic_logger_loaded?
        raise LoadError, "semantic_logger gem is required for Quonfig::SemanticLoggerFilter. Add `gem 'semantic_logger'` to your Gemfile."
      end

      @client = client
      @config_key = config_key
    end

    # SemanticLogger filter contract: return true to emit, false to suppress.
    # Missing config key → return true so SemanticLogger's static level decides.
    def call(log)
      configured = @client.get(@config_key, nil, context_for(log))
      return true if configured.nil?

      log_severity = LEVELS[log.level] || LEVELS[:debug]
      min_severity = LEVELS[normalize_level(configured)] || LEVELS[:debug]
      log_severity >= min_severity
    end

    private

    def context_for(log)
      { LOGGER_CONTEXT_NAME => { LOGGER_CONTEXT_KEY_PROP => log.name.to_s } }
    end

    def normalize_level(level)
      case level
      when Symbol  then level.downcase
      when String  then level.downcase.to_sym
      when Integer
        # LogLevel ints from old proto: 1=trace … 9=fatal. Best-effort map.
        case level
        when 1 then :trace
        when 2 then :debug
        when 3 then :info
        when 5 then :warn
        when 6 then :error
        when 9 then :fatal
        else :debug
        end
      else :debug
      end
    end
  end
end
