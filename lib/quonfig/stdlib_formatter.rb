# frozen_string_literal: true

module Quonfig
  # Adapter that plugs Quonfig's dynamic log-level evaluation into Ruby's
  # built-in +::Logger+. The formatter is a proc with the stdlib Logger
  # contract — +(severity, datetime, progname, msg) -> String+ — that calls
  # +client.should_log?+ before each line and returns either a formatted
  # record (emit) or an empty string (suppress).
  #
  # Returning an empty string is how you "drop" a log line through the
  # formatter hook: +::Logger+ writes exactly what the formatter returns,
  # so an empty string produces zero visible output. We deliberately do NOT
  # return +nil+ — stdlib Logger would still call +.to_s+ (→ "") on some
  # Ruby versions but would emit "\n" from +::Logger::Formatter+ subclasses
  # that pre-wrap the message. Empty string is the portable zero-output
  # sentinel.
  #
  # Usage:
  #   client = Quonfig::Client.new(logger_key: 'log-level.my-app')
  #   logger = ::Logger.new($stdout)
  #   logger.formatter = client.stdlib_formatter           # progname wins
  #   # or
  #   logger.formatter = client.stdlib_formatter(logger_name: 'MyApp::Svc')
  #
  # +logger_name+ (optional) is the fallback when +progname+ is nil / the
  # caller doesn't pass one to the individual log call. If both are set,
  # +logger_name+ wins — matching ReforgeHQ's stdlib_formatter semantics.
  #
  # Level mapping (stdlib severity string → quonfig level symbol):
  #
  #   "DEBUG"   -> :debug
  #   "INFO"    -> :info
  #   "WARN"    -> :warn
  #   "ERROR"   -> :error
  #   "FATAL"   -> :fatal
  #   "ANY"     -> :fatal  (Logger::UNKNOWN — treat as top severity)
  #   other     -> :info   (defensive — unknown labels don't silently drop)
  #
  # No normalization is applied to +progname+ / +logger_name+; they are
  # passed verbatim into +quonfig-sdk-logging.key+ so customer matching
  # rules can target exact class names (e.g. +PROP_STARTS_WITH_ONE_OF
  # "MyApp::Services::"+). Parallels the SemanticLoggerFilter.
  module StdlibFormatter
    # Ruby stdlib Logger severity strings → quonfig level symbols. Covers
    # every label the stdlib actually emits.
    SEVERITY_TO_LEVEL = {
      'DEBUG' => :debug,
      'INFO'  => :info,
      'WARN'  => :warn,
      'ERROR' => :error,
      'FATAL' => :fatal,
      'ANY'   => :fatal # Logger::UNKNOWN formats as "ANY"
    }.freeze

    # Build a formatter Proc. Exposed on +Quonfig::Client#stdlib_formatter+;
    # callers should prefer the client helper.
    #
    # @param client [Quonfig::Client] the client whose +should_log?+ gates output.
    # @param logger_name [String, nil] fallback logger identifier when the
    #   Logger call-site doesn't supply a progname.
    # @return [Proc] a (severity, datetime, progname, msg) → String proc.
    def self.build(client, logger_name: nil)
      unless client.logger_key
        raise Quonfig::Error,
              'logger_key must be set at init to use stdlib_formatter. ' \
              'Pass `logger_key:` to Quonfig::Options.new, or call ' \
              'semantic_logger_filter(config_key:) / get(config_key) directly.'
      end

      # Arity MUST be 4 — ::Logger invokes the formatter with exactly that
      # signature. Declared explicitly (not *args) so arity is 4, matching
      # ::Logger::Formatter#call.
      proc do |severity, datetime, progname, msg|
        path = logger_name || progname
        level = SEVERITY_TO_LEVEL[severity.to_s.upcase] || :info

        if client.should_log?(logger_path: path, desired_level: level)
          format_record(severity, datetime, progname, msg)
        else
          ''
        end
      end
    end

    # Default record formatter. Matches ::Logger::Formatter's general shape
    # ("I, [timestamp pid] SEVERITY -- progname: message") but without the
    # process-id first-letter noise so output is readable in tests and
    # modern dev logs. Callers who want a different format can wrap the
    # gated proc with their own renderer.
    def self.format_record(severity, datetime, progname, msg)
      ts = datetime.respond_to?(:strftime) ? datetime.strftime('%Y-%m-%dT%H:%M:%S.%6N') : datetime.to_s
      "[#{ts}] #{severity} -- #{progname}: #{msg}\n"
    end
  end
end
