# frozen_string_literal: true

require 'json'
require 'timeout'

module Quonfig
  # Public Quonfig SDK client.
  #
  # Wires the JSON stack: Quonfig::ConfigStore + Quonfig::Evaluator +
  # Quonfig::Resolver. Three modes are supported:
  #
  # 1. +datadir:+ (offline) -- load a workspace from the local filesystem.
  # 2. +store:+ (test harness) -- caller-supplied ConfigStore, no I/O.
  # 3. network mode (default) -- HTTP fetch from +api_urls+ populates the
  #    ConfigStore, then (if enabled) an SSE subscription keeps it live.
  #
  # Network mode is the happy path for production SDK usage. The protobuf
  # stack was retired in qfg-dk6.32; HTTP + SSE were wired back through Client
  # in qfg-s7h.
  class Client
    LOG = Quonfig::InternalLogger.new(self)

    attr_reader :options, :resolver, :store, :evaluator, :instance_hash,
                :config_loader, :telemetry_reporter

    def initialize(options = nil, store: nil, **option_kwargs)
      @options =
        if options.is_a?(Quonfig::Options)
          options
        elsif options.is_a?(Hash)
          Quonfig::Options.new(options.merge(option_kwargs))
        else
          Quonfig::Options.new(option_kwargs)
        end
      @global_context = build_initial_global_context(@options)
      @instance_hash = SecureRandom.uuid
      @store = store || Quonfig::ConfigStore.new
      @evaluator = Quonfig::Evaluator.new(@store, env_id: @options.environment)
      @resolver = Quonfig::Resolver.new(@store, @evaluator)
      @semantic_logger_filters = {}
      @sse_client = nil
      @poll_thread = nil
      @stopped = false
      @telemetry_reporter = nil

      # If the caller injected a store, we're in test/bootstrap mode; skip I/O.
      return if store

      if @options.datadir
        load_datadir_into_store
      else
        initialize_network_mode
      end

      initialize_telemetry
    end

    # ---- Lookup --------------------------------------------------------

    def get(key, default = NO_DEFAULT_PROVIDED, jit_context = NO_DEFAULT_PROVIDED)
      ctx = build_context(jit_context)
      record_context_for_telemetry(ctx)
      result =
        begin
          @resolver.get(key, ctx)
        rescue Quonfig::Errors::MissingDefaultError
          # The Resolver raises (matching Quonfig.get_or_raise semantics).
          # The Client's get applies the caller-provided default *or* the
          # configured on_no_default policy via handle_missing.
          nil
        end
      return handle_missing(key, default) if result.nil?

      record_evaluation_for_telemetry(result)
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

    # Build a formatter Proc for Ruby's built-in +::Logger+. The returned
    # proc honors dynamic log levels from the client's +logger_key+ config:
    # for each log call, it evaluates +should_log?+ and either formats the
    # record or returns an empty string (suppressing output).
    #
    # Matches ReforgeHQ's +stdlib_formatter+ API name (snake_case).
    #
    # Usage:
    #   logger = ::Logger.new($stdout)
    #   logger.formatter = client.stdlib_formatter                       # uses progname
    #   logger.formatter = client.stdlib_formatter(logger_name: 'MyApp') # fixed name
    #
    # Raises +Quonfig::Error+ if +logger_key+ was not set at init — parallels
    # +should_log?+'s behavior.
    #
    # @param logger_name [String, nil] fallback logger identifier used when
    #   +progname+ isn't supplied by the Logger call site. If both are
    #   present, +logger_name+ wins.
    # @return [Proc] a +(severity, datetime, progname, msg) -> String+ proc.
    def stdlib_formatter(logger_name: nil)
      Quonfig::StdlibFormatter.build(self, logger_name: logger_name)
    end

    # The configured +logger_key+ from Options — the Quonfig config key the
    # higher-level +should_log?+ helper evaluates per-logger. +nil+ if the
    # client was not configured for dynamic log levels.
    def logger_key
      @options.logger_key
    end

    # Higher-level log-level check — a convenience on top of the primitive
    # +get+. Evaluates the client's +logger_key+ config and returns whether
    # a message at +desired_level+ should be emitted for +logger_path+.
    #
    # The SDK injects +logger_path+ under the +quonfig-sdk-logging+ named
    # context with property +key+ so a single log-level config can drive
    # per-logger overrides via the normal rule engine (e.g.
    # PROP_STARTS_WITH_ONE_OF "MyApp::Services::").
    #
    # +logger_path+ is passed through verbatim — the SDK does not normalize
    # it. Callers may pass any identifier shape their host language prefers
    # (dotted, colon, slash, etc.) and author matching rules in the config
    # against that exact shape.
    #
    # Parallels sdk-node's +shouldLog({loggerPath})+ and sdk-go's
    # +ShouldLogPath+.
    #
    # Raises +Quonfig::Error+ if +logger_key+ was not set on the client —
    # use +semantic_logger_filter(config_key:)+ directly if you want to
    # evaluate a specific key without declaring it at init time.
    #
    # @param logger_path [String] native logger name (typically a class name).
    # @param desired_level [Symbol, String] the level the caller wants to
    #   emit at (:trace, :debug, :info, :warn, :error, :fatal).
    # @param contexts [Hash] optional extra context to merge with the
    #   injected logger context.
    # @return [Boolean] true if the message should be emitted.
    def should_log?(logger_path:, desired_level:, contexts: {})
      unless logger_key
        raise Quonfig::Error,
              'logger_key must be set at init to use should_log?(logger_path:, ...). ' \
              'Pass `logger_key:` to Quonfig::Options.new, or call ' \
              'semantic_logger_filter(config_key:) / get(config_key) directly.'
      end

      logger_context = {
        Quonfig::SemanticLoggerFilter::LOGGER_CONTEXT_NAME => {
          Quonfig::SemanticLoggerFilter::LOGGER_CONTEXT_KEY_PROP => logger_path
        }
      }
      merged = merge_contexts(normalize_context(contexts), logger_context)

      configured = get(logger_key, nil, merged)
      return true if configured.nil?

      desired_severity = Quonfig::SemanticLoggerFilter::LEVELS[normalize_log_level(desired_level)] ||
                         Quonfig::SemanticLoggerFilter::LEVELS[:debug]
      min_severity     = Quonfig::SemanticLoggerFilter::LEVELS[normalize_log_level(configured)] ||
                         Quonfig::SemanticLoggerFilter::LEVELS[:debug]
      desired_severity >= min_severity
    end

    def on_update(&block)
      @on_update = block
    end

    def stop
      @stopped = true
      begin
        @sse_client&.close
      rescue StandardError => e
        LOG.debug "Error closing SSE client: #{e.message}"
      end
      @sse_client = nil

      thread = @poll_thread
      @poll_thread = nil
      thread&.kill

      begin
        @telemetry_reporter&.stop
      rescue StandardError => e
        LOG.debug "Error stopping telemetry reporter: #{e.message}"
      end
      @telemetry_reporter = nil
    end

    def fork
      self.class.new(@options.for_fork)
    end

    def inspect
      "#<Quonfig::Client:#{object_id} environment=#{@options.environment.inspect}>"
    end

    private

    # Construct and start the telemetry reporter if the options permit it.
    # The reporter runs on a background thread and periodically POSTs
    # context-shape and example-context batches to +telemetry_destination+.
    def initialize_telemetry
      shape_aggregator = nil
      example_aggregator = nil
      summaries_aggregator = nil

      if @options.collect_max_shapes.to_i > 0
        shape_aggregator = Quonfig::Telemetry::ContextShapeAggregator.new(
          max_shapes: @options.collect_max_shapes
        )
      end

      if @options.collect_max_example_contexts.to_i > 0
        example_aggregator = Quonfig::Telemetry::ExampleContextsAggregator.new(
          max_contexts: @options.collect_max_example_contexts
        )
      end

      if @options.collect_max_evaluation_summaries.to_i > 0
        summaries_aggregator = Quonfig::Telemetry::EvaluationSummariesAggregator.new(
          max_keys: @options.collect_max_evaluation_summaries
        )
      end

      return if shape_aggregator.nil? && example_aggregator.nil? && summaries_aggregator.nil?

      @telemetry_reporter = Quonfig::Telemetry::TelemetryReporter.new(
        options: @options,
        instance_hash: @instance_hash,
        context_shape_aggregator: shape_aggregator,
        example_contexts_aggregator: example_aggregator,
        evaluation_summaries_aggregator: summaries_aggregator,
        sync_interval: @options.collect_sync_interval
      )

      return unless @telemetry_reporter.enabled?

      @telemetry_reporter.start
    rescue StandardError => e
      LOG.warn "[quonfig] Telemetry init failed: #{e.class}: #{e.message}"
      @telemetry_reporter = nil
    end

    # Feed a matched EvalResult into the evaluation_summaries aggregator.
    # A no-op when telemetry is disabled or eval-summaries collection is off.
    def record_evaluation_for_telemetry(result)
      return if @telemetry_reporter.nil?
      return if result.nil?

      config = result.config
      return if config.nil?

      @telemetry_reporter.record_evaluation(
        config_id: config_field(config, :id),
        config_key: config_field(config, :key),
        config_type: config_field(config, :type),
        conditional_value_index: result.rule_index,
        weighted_value_index: result.weighted_value_index,
        selected_value: result.unwrapped_value,
        reason: result.wire_reason
      )
    rescue StandardError => e
      LOG.debug "[quonfig] Telemetry record_evaluation error: #{e.class}: #{e.message}"
    end

    def config_field(config, key)
      return nil if config.nil?

      config[key.to_s] || config[key.to_sym]
    end

    # Feed every evaluated context into the telemetry aggregators. A no-op
    # when telemetry is disabled or no aggregators are active.
    def record_context_for_telemetry(context)
      return if @telemetry_reporter.nil?
      return if context.nil?

      context_obj = context.is_a?(Quonfig::Context) ? context : Quonfig::Context.new(context)
      return if context_obj.blank?

      @telemetry_reporter.record(context_obj)
    rescue StandardError => e
      LOG.debug "[quonfig] Telemetry record error: #{e.class}: #{e.message}"
    end

    def load_datadir_into_store
      envelope = Quonfig::Datadir.load_envelope(@options.datadir, @options.environment)
      envelope.configs.each { |cfg| @store.set(cfg['key'], cfg) }
    end

    # Initialize network mode: sync HTTP fetch (bounded by
    # initialization_timeout_sec) then start SSE + polling as requested.
    def initialize_network_mode
      if @options.sdk_key.nil? || @options.sdk_key.to_s.strip.empty?
        raise Quonfig::Errors::InvalidSdkKeyError, @options.sdk_key
      end

      @config_loader = Quonfig::ConfigLoader.new(@store, @options)

      perform_initial_fetch

      sse_started = @options.enable_sse && start_sse

      # Polling is a fallback: if SSE is off or failed to start, poll. This
      # avoids double-work when SSE is healthy but still refreshes the store
      # in environments that block SSE (corporate proxies, Lambda, etc.).
      start_polling if @options.enable_polling && !sse_started
    end

    def perform_initial_fetch
      timeout = @options.initialization_timeout_sec || 10
      result = :failed

      begin
        Timeout.timeout(timeout) do
          result = @config_loader.fetch!
        end
      rescue Timeout::Error
        handle_init_failure(
          Quonfig::Errors::InitializationTimeoutError.new(timeout, nil)
        )
        return
      end

      handle_init_failure(RuntimeError.new('Config fetch failed against all api_urls')) if result == :failed
    end

    def handle_init_failure(err)
      if @options.on_init_failure == Quonfig::Options::ON_INITIALIZATION_FAILURE::RETURN
        LOG.warn "[quonfig] Initialization did not complete cleanly; continuing with empty store: #{err.message}"
        return
      end

      raise err
    end

    # Returns true if SSE started successfully, false otherwise. A false here
    # signals the caller to fall back to polling.
    def start_sse
      return false if @options.sse_api_urls.nil? || @options.sse_api_urls.empty?

      @sse_client = Quonfig::SSEConfigClient.new(@options, @config_loader)
      @sse_client.start do |envelope, _event, _source|
        next if @stopped
        begin
          @config_loader.apply_envelope(envelope)
          @on_update&.call
        rescue StandardError => e
          LOG.warn "[quonfig] Error applying SSE envelope: #{e.message}"
        end
      end
      true
    rescue StandardError => e
      LOG.warn "[quonfig] SSE start failed: #{e.message}"
      @sse_client = nil
      false
    end

    def start_polling
      poll_interval = @options.respond_to?(:poll_interval) && @options.poll_interval ? @options.poll_interval : 60
      return if poll_interval <= 0

      @poll_thread = Thread.new do
        Thread.current.name = 'quonfig-poller'
        loop do
          break if @stopped
          sleep poll_interval
          break if @stopped

          begin
            @config_loader.fetch!
            @on_update&.call
          rescue StandardError => e
            LOG.warn "[quonfig] Polling error: #{e.message}"
          end
        end
      end
    end

    def build_context(jit_context)
      jit = jit_context == NO_DEFAULT_PROVIDED ? nil : normalize_context(jit_context)
      merge_contexts(@global_context, jit)
    end

    # Combine the customer-supplied globalContext with the optional dev
    # context loaded from ~/.quonfig/tokens.json. Dev context goes UNDER the
    # customer's so any explicit `quonfig-user` keys win on collision.
    def build_initial_global_context(options)
      customer = normalize_context(options.global_context)
      enabled = options.enable_quonfig_user_context == true ||
                ENV['QUONFIG_DEV_CONTEXT'] == 'true'
      return customer unless enabled

      dev = Quonfig::DevContext.load_quonfig_user_context
      return customer if dev.nil?

      merge_contexts(dev, customer)
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

    def normalize_log_level(level)
      case level
      when Symbol then level.downcase
      when String then level.downcase.to_sym
      else level
      end
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
