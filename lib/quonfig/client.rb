# frozen_string_literal: true

require 'json'

module Quonfig
  # Public Quonfig SDK client.
  #
  # Wires the new JSON stack: Quonfig::ConfigStore + Quonfig::Evaluator +
  # Quonfig::Resolver. The legacy protobuf-driven ConfigClient/ConfigResolver
  # path was removed in qfg-dk6.32. Network-mode (HTTP fetch + SSE updates) is
  # not yet wired through Client; today the supported entry points are
  # +datadir:+ (offline workspace) and +store:+ (caller-supplied
  # Quonfig::ConfigStore, used by tests).
  class Client
    LOG = Quonfig::InternalLogger.new(self)

    attr_reader :options, :resolver, :store, :evaluator, :instance_hash

    def initialize(options = nil, store: nil, **option_kwargs)
      @options =
        if options.is_a?(Quonfig::Options)
          options
        elsif options.is_a?(Hash)
          Quonfig::Options.new(options.merge(option_kwargs))
        else
          Quonfig::Options.new(option_kwargs)
        end
      @global_context = normalize_context(@options.global_context)
      @instance_hash = SecureRandom.uuid
      @store = store || build_store
      @evaluator = Quonfig::Evaluator.new(@store, env_id: @options.environment)
      @resolver = Quonfig::Resolver.new(@store, @evaluator)
      @semantic_logger_filters = {}
    end

    # ---- Lookup --------------------------------------------------------

    def get(key, default = NO_DEFAULT_PROVIDED, jit_context = NO_DEFAULT_PROVIDED)
      ctx = build_context(jit_context)
      result = @resolver.get(key, ctx)
      return handle_missing(key, default) if result.nil?

      result.unwrapped_value
    end

    def get_string(key, default: NO_DEFAULT_PROVIDED, context: NO_DEFAULT_PROVIDED)
      typed_get(key, String, default: default, context: context)
    end

    def get_int(key, default: NO_DEFAULT_PROVIDED, context: NO_DEFAULT_PROVIDED)
      typed_get(key, Integer, default: default, context: context)
    end

    def get_float(key, default: NO_DEFAULT_PROVIDED, context: NO_DEFAULT_PROVIDED)
      typed_get(key, Float, default: default, context: context)
    end

    def get_bool(key, default: NO_DEFAULT_PROVIDED, context: NO_DEFAULT_PROVIDED)
      typed_get(key, :bool, default: default, context: context)
    end

    def get_string_list(key, default: NO_DEFAULT_PROVIDED, context: NO_DEFAULT_PROVIDED)
      typed_get(key, :string_list, default: default, context: context)
    end

    def get_duration(key, default: NO_DEFAULT_PROVIDED, context: NO_DEFAULT_PROVIDED)
      typed_get(key, :duration, default: default, context: context)
    end

    def get_json(key, default: NO_DEFAULT_PROVIDED, context: NO_DEFAULT_PROVIDED)
      typed_get(key, :json, default: default, context: context)
    end

    def enabled?(feature_name, jit_context = NO_DEFAULT_PROVIDED)
      value = get(feature_name, false, jit_context)
      value == true || value == 'true'
    end

    def defined?(key)
      !@store.get(key).nil?
    end

    def keys
      @store.keys
    end

    # ---- Context binding ----------------------------------------------

    def in_context(properties)
      bound = Quonfig::BoundClient.new(self, properties)
      block_given? ? yield(bound) : bound
    end

    def with_context(properties, &block)
      if block_given?
        in_context(properties, &block)
      else
        Quonfig::BoundClient.new(self, properties)
      end
    end

    # ---- Filters & helpers --------------------------------------------

    def semantic_logger_filter(config_key:)
      @semantic_logger_filters[config_key] ||=
        Quonfig::SemanticLoggerFilter.new(self, config_key: config_key)
    end

    def on_update(&block)
      @on_update = block
    end

    def stop
      # No background threads in datadir mode; placeholder for the future
      # SSE/poll path so callers can use this method symmetrically.
    end

    def fork
      self.class.new(@options.for_fork)
    end

    def inspect
      "#<Quonfig::Client:#{object_id} environment=#{@options.environment.inspect}>"
    end

    private

    def build_store
      if @options.datadir
        Quonfig::Datadir.load_store(@options.datadir, @options.environment)
      else
        Quonfig::ConfigStore.new
      end
    end

    def build_context(jit_context)
      jit = jit_context == NO_DEFAULT_PROVIDED ? nil : normalize_context(jit_context)
      merge_contexts(@global_context, jit)
    end

    def normalize_context(ctx)
      return {} if ctx.nil?
      return ctx if ctx.is_a?(Hash)

      raise ArgumentError, "Quonfig context must be a Hash, got #{ctx.class}"
    end

    # One-level-deep merge per named context (mirrors sdk-node's mergeContexts):
    # later values override earlier within the same named context; keys unique
    # to each side are preserved.
    def merge_contexts(left, right)
      return right || {} if left.nil? || left.empty?
      return left if right.nil? || right.empty?

      merged = {}
      left.each  { |name, ctx| merged[name] = ctx.is_a?(Hash) ? ctx.dup : ctx }
      right.each do |name, ctx|
        if merged[name].is_a?(Hash) && ctx.is_a?(Hash)
          merged[name] = merged[name].merge(ctx)
        else
          merged[name] = ctx.is_a?(Hash) ? ctx.dup : ctx
        end
      end
      merged
    end

    def handle_missing(key, default)
      return default if default != NO_DEFAULT_PROVIDED

      if @options.on_no_default == Quonfig::Options::ON_NO_DEFAULT::RAISE
        raise Quonfig::Errors::MissingDefaultError, key
      end

      nil
    end

    def typed_get(key, expected_type, default:, context:)
      jit = context == NO_DEFAULT_PROVIDED ? NO_DEFAULT_PROVIDED : context
      value = get(key, default, jit)

      # Missing path: resolver returned the caller's default (or nil under
      # on_no_default=:return_nil) — skip type coercion.
      return value if default != NO_DEFAULT_PROVIDED && value.equal?(default)
      return nil if value.nil?

      coerce_and_check(key, value, expected_type)
    end

    def coerce_and_check(key, value, expected_type)
      case expected_type
      when :bool
        unless value == true || value == false
          raise Quonfig::Errors::TypeMismatchError.new(key, 'Boolean', value)
        end
        value
      when :string_list
        arr = value.is_a?(Array) ? value : nil
        unless arr && arr.all? { |v| v.is_a?(String) }
          raise Quonfig::Errors::TypeMismatchError.new(key, 'Array<String>', value)
        end
        arr
      when :duration
        return value.to_i if value.is_a?(Numeric)
        if value.is_a?(String)
          return (Quonfig::Duration.parse(value) * 1000).to_i
        end
        raise Quonfig::Errors::TypeMismatchError.new(key, 'ISO-8601 Duration', value)
      when :json
        # JSON values are returned as-is (Hash, Array, or scalar from the wire).
        value
      when Class
        unless value.is_a?(expected_type)
          raise Quonfig::Errors::TypeMismatchError.new(key, "expected #{expected_type}", value)
        end
        value
      else
        value
      end
    end
  end
end
