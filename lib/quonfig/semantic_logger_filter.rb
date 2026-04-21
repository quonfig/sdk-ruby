# frozen_string_literal: true

module Quonfig
  # SemanticLogger filter that gates log output by a single Quonfig config
  # whose rules target the logger via the +quonfig.logger-name+ context
  # property.
  #
  # Usage:
  #   filter = client.semantic_logger_filter(config_key: 'log-levels.my-app')
  #   SemanticLogger.add_appender(io: $stdout, filter: filter)
  #
  # The filter normalizes the SemanticLogger logger name to dotted snake_case
  # (e.g. +MyApp::Foo::Bar+ → +my_app.foo.bar+) and exposes it to the
  # evaluator under +quonfig.logger-name+ so the customer's Quonfig config can
  # discriminate per-logger via PROP_STARTS_WITH_ONE_OF / PROP_IS_ONE_OF
  # rules. Lookup is O(1): one +client.get+ call per log line.
  class SemanticLoggerFilter
    LEVELS = {
      trace: 0,
      debug: 1,
      info:  2,
      warn:  3,
      error: 4,
      fatal: 5
    }.freeze

    LOGGER_NAME_CONTEXT_KEY = 'quonfig.logger-name'

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

    # Normalize a SemanticLogger logger name to the dotted snake_case form
    # the customer writes targeting rules against.
    #   MyApp::Foo::Bar → my_app.foo.bar
    #   HTMLParser      → html_parser
    def normalize(name)
      name.to_s
          .gsub('::', '.')
          .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z\d])([A-Z])/, '\1_\2')
          .downcase
    end

    private

    def context_for(log)
      { 'quonfig' => { 'logger-name' => normalize(log.name) } }
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
