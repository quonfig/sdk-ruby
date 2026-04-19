# frozen_string_literal: true

module Quonfig
  # SemanticLogger filter that gates log output by a Quonfig config lookup.
  #
  # Logger name → config key:
  #   MyApp::Foo::Bar  →  log-levels.my_app.foo.bar  (with default prefix)
  #
  # Lookup is exact-match only. If the key is missing, the filter returns
  # true and lets SemanticLogger's static level decide — no hierarchy walk.
  class SemanticLoggerFilter
    LEVELS = {
      trace: 0,
      debug: 1,
      info:  2,
      warn:  3,
      error: 4,
      fatal: 5
    }.freeze

    DEFAULT_KEY_PREFIX = 'log-levels.'

    def self.semantic_logger_loaded?
      defined?(SemanticLogger)
    end

    def initialize(client, key_prefix: DEFAULT_KEY_PREFIX)
      unless self.class.semantic_logger_loaded?
        raise LoadError, "semantic_logger gem is required for Quonfig::SemanticLoggerFilter. Add `gem 'semantic_logger'` to your Gemfile."
      end

      @client = client
      @key_prefix = key_prefix
    end

    # SemanticLogger filter contract: return true to emit, false to suppress.
    def call(log)
      key = @key_prefix + normalize(log.name)
      configured = @client.get(key, nil)
      return true if configured.nil?

      log_severity = LEVELS[log.level] || LEVELS[:debug]
      min_severity = LEVELS[configured.to_s.downcase.to_sym] || LEVELS[:debug]
      log_severity >= min_severity
    end

    # Convert CamelCase and :: into a dotted snake_case path.
    # MyApp::Foo::Bar → my_app.foo.bar
    # HTMLParser      → html_parser
    def normalize(name)
      name.to_s
          .gsub('::', '.')
          .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z\d])([A-Z])/, '\1_\2')
          .downcase
    end
  end
end
