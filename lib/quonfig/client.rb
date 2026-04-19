# frozen_string_literal: true

require 'uuid'

module Quonfig
  class Client
    LOG = Quonfig::InternalLogger.new(self)
    MAX_SLEEP_SEC = 10
    BASE_SLEEP_SEC = 0.5

    attr_reader :namespace, :interceptor, :sdk_key, :options, :instance_hash

    def initialize(options = Quonfig::Options.new)
      @options = options.is_a?(Quonfig::Options) ? options : Quonfig::Options.new(options)
      @namespace = @options.namespace
      @stubs = {}
      @instance_hash = ::UUID.new.generate

      if @options.local_only?
        LOG.debug 'Quonfig SDK Running in Local Mode'
      elsif @options.datafile?
        LOG.debug 'Quonfig SDK Running in DataFile Mode'
      else
        @sdk_key = @options.sdk_key
        raise Quonfig::Errors::InvalidSdkKeyError, @sdk_key if @sdk_key.nil? || @sdk_key.empty? || sdk_key.count('-') < 1
      end

      context.clear

      Quonfig::Context.global_context = @options.global_context

      # start config client
      config_client
    end

    def in_context(properties, &block)
      bound = Quonfig::BoundClient.new(self, properties)
      Quonfig::Context.with_context(properties) do
        block.call(bound)
      end
    end

    def with_context(properties, &block)
      if block_given?
        in_context(properties, &block)
      else
        Quonfig::BoundClient.new(self, properties)
      end
    end

    def context
      Quonfig::Context.current
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
      typed_get(key, Hash, default: default, context: context)
    end

    def config_client(timeout: 5.0)
      @config_client ||= Quonfig::ConfigClient.new(self, timeout)
    end

    def stop
      @config_client.stop
    end

    def feature_flag_client
      @feature_flag_client ||= Quonfig::FeatureFlagClient.new(self)
    end

    def semantic_logger_filter(key_prefix: Quonfig::SemanticLoggerFilter::DEFAULT_KEY_PREFIX)
      @semantic_logger_filters ||= {}
      @semantic_logger_filters[key_prefix] ||= Quonfig::SemanticLoggerFilter.new(self, key_prefix: key_prefix)
    end

    def context_shape_aggregator
      return nil if @options.collect_max_shapes <= 0

      @context_shape_aggregator ||= ContextShapeAggregator.new(client: self, max_shapes: @options.collect_max_shapes,
                                                               sync_interval: @options.collect_sync_interval)
    end

    def example_contexts_aggregator
      return nil if @options.collect_max_example_contexts <= 0

      @example_contexts_aggregator ||= ExampleContextsAggregator.new(
        client: self,
        max_contexts: @options.collect_max_example_contexts,
        sync_interval: @options.collect_sync_interval
      )
    end

    def evaluation_summary_aggregator
      return nil if @options.collect_max_evaluation_summaries <= 0

      @evaluation_summary_aggregator ||= EvaluationSummaryAggregator.new(
        client: self,
        max_keys: @options.collect_max_evaluation_summaries,
        sync_interval: @options.collect_sync_interval
      )
    end

    def on_update(&block)
      resolver.on_update(&block)
    end

    def enabled?(feature_name, jit_context = NO_DEFAULT_PROVIDED)
      feature_flag_client.feature_is_on_for?(feature_name, jit_context)
    end

    def get(key, default = NO_DEFAULT_PROVIDED, jit_context = NO_DEFAULT_PROVIDED)
      if is_ff?(key)
        feature_flag_client.get(key, jit_context, default: default)
      else
        config_client.get(key, default, jit_context)
      end
    end

    def post(path, body)
      Quonfig::HttpConnection.new(@options.telemetry_destination, @sdk_key).post(path, body)
    end

    def inspect
      "#<Quonfig::Client:#{object_id} namespace=#{namespace}>"
    end

    def resolver
      config_client.resolver
    end

    # When starting a forked process, use this to re-use the options
    # on_worker_boot do
    #   Prefab.fork
    # end
    def fork
      Quonfig::Client.new(@options.for_fork)
    end

    def defined?(key)
      !!config_client.send(:raw, key)
    end

    def is_ff?(key)
      raw = config_client.send(:raw, key)

      raw && raw.allowable_values.any?
    end

    private

    def typed_get(key, expected_type, default:, context:)
      jit_context = context == NO_DEFAULT_PROVIDED ? NO_DEFAULT_PROVIDED : context
      value = get(key, default, jit_context)

      # Missing-key path: resolver returned the caller's default (or nil under on_no_default=:return_nil) — skip type coercion
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
        arr = value.respond_to?(:to_a) ? value.to_a : value
        unless arr.is_a?(Array) && arr.all? { |v| v.is_a?(String) }
          raise Quonfig::Errors::TypeMismatchError.new(key, 'Array<String>', value)
        end
        arr
      when :duration
        unless value.is_a?(Quonfig::Duration)
          raise Quonfig::Errors::TypeMismatchError.new(key, 'ISO-8601 Duration', value)
        end
        (value.in_seconds * 1000).to_i
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
