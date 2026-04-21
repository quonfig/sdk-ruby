# frozen_string_literal: true

module Quonfig
  LOG = Quonfig::InternalLogger.new(self)
  @@lock = Concurrent::ReadWriteLock.new

  def self.init(options = Quonfig::Options.new)
    unless @singleton.nil?
      LOG.warn 'Quonfig already initialized.'
      return @singleton
    end

    @@lock.with_write_lock do
      @singleton = Quonfig::Client.new(options)
    end
  end

  def self.fork
    ensure_initialized
    @@lock.with_write_lock { @singleton = @singleton.fork }
  end

  def self.get(key, default = NO_DEFAULT_PROVIDED, jit_context = NO_DEFAULT_PROVIDED)
    ensure_initialized(key)
    @singleton.get(key, default, jit_context)
  end

  def self.enabled?(feature_name, jit_context = NO_DEFAULT_PROVIDED)
    ensure_initialized(feature_name)
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

  def self.semantic_logger_filter(config_key:)
    ensure_initialized
    @singleton.semantic_logger_filter(config_key: config_key)
  end

  def self.defined?(key)
    ensure_initialized(key)
    @singleton.defined?(key)
  end

  def self.ensure_initialized(key = nil)
    if !defined?(@singleton) || @singleton.nil?
      raise Quonfig::Errors::UninitializedError.new(key)
    end
  end
end
