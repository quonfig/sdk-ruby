# frozen_string_literal: true

module Quonfig
  LOG = Quonfig::InternalLogger.new(self)
  @@lock = Concurrent::ReadWriteLock.new
  @config_has_loaded = false

  def self.init(options = Quonfig::Options.new)
    unless @singleton.nil?
      LOG.warn 'Quonfig already initialized.'
      return @singleton
    end

    @@lock.with_write_lock {
      @singleton = Quonfig::Client.new(options)
    }
  end

  def self.fork
    ensure_initialized
    @@lock.with_write_lock {
      @singleton = @singleton.fork
    }
  end

  def self.set_rails_loggers
    ensure_initialized
    @singleton.set_rails_loggers
  end

  def self.get(key, default = NO_DEFAULT_PROVIDED, jit_context = NO_DEFAULT_PROVIDED)
    ensure_initialized key
    @singleton.get(key, default, jit_context)
  end

  def self.enabled?(feature_name, jit_context = NO_DEFAULT_PROVIDED)
    ensure_initialized feature_name
    @singleton.enabled?(feature_name, jit_context)
  end

  def self.with_context(properties, &block)
    ensure_initialized
    @singleton.with_context(properties, &block)
  end

  def self.instance
    ensure_initialized
    @singleton
  end

  def self.semantic_logger_filter(key_prefix: Quonfig::SemanticLoggerFilter::DEFAULT_KEY_PREFIX)
    ensure_initialized
    @singleton.semantic_logger_filter(key_prefix: key_prefix)
  end

  def self.log_filter
    InternalLogger.using_quonfig_log_filter!
    return Proc.new do |log|
      if defined?(@singleton) && !@singleton.nil? && @singleton.config_client.initialized?
        @singleton.semantic_logger_filter.call(log)
      else
        bootstrap_log_level(log)
      end
    end
  end

  def self.finish_init!
    @config_has_loaded = true
  end

  def self.bootstrap_log_level(log)
    return true unless defined?(SemanticLogger)

    level = ENV['QUONFIG_LOG_CLIENT_BOOTSTRAP_LOG_LEVEL'] ? ENV['QUONFIG_LOG_CLIENT_BOOTSTRAP_LOG_LEVEL'].downcase.to_sym : :warn
    SemanticLogger::Levels.index(level) <= SemanticLogger::Levels.index(log.level)
  end

  def self.defined?(key)
    ensure_initialized key
    @singleton.defined?(key)
  end

  def self.is_ff?(key)
    ensure_initialized key
    @singleton.is_ff?(key)
  end

  # Generate the JavaScript snippet to bootstrap the client SDK. This will
  # include the configuration values that are permitted to be sent to the
  # client SDK.
  #
  # If the context provided to the client SDK is not the same as the context
  # used to generate the configuration values, the client SDK will still
  # generate a fetch to get the correct values for the context.
  #
  # Any keys that could not be resolved will be logged as a warning to the
  # console.
  def self.bootstrap_javascript(context)
    ensure_initialized
    Quonfig::JavaScriptStub.new(@singleton).bootstrap(context)
  end

  # Generate the JavaScript snippet to *replace* the client SDK. Use this to
  # get `prefab.get` and `prefab.isEnabled` functions on the window object.
  #
  # Only use this if you are not using the client SDK and do not need
  # client-side context.
  #
  # Any keys that could not be resolved will be logged as a warning to the
  # console.
  #
  # You can pass an optional callback function to be called with the key and
  # value of each configuration value. This can be useful for logging,
  # tracking experiment exposure, etc.
  #
  # e.g.
  # - `Prefab.generate_javascript_stub(context, "reportExperimentExposure")`
  # - `Prefab.generate_javascript_stub(context, "(key,value)=>{console.log({eval: 'eval', key,value})}")`
  def self.generate_javascript_stub(context, callback = nil)
    ensure_initialized
    Quonfig::JavaScriptStub.new(@singleton).generate_stub(context, callback)
  end

  private

  def self.ensure_initialized(key = nil)
    if not defined? @singleton or @singleton.nil?
      raise Quonfig::Errors::UninitializedError.new(key)
    end
  end
end