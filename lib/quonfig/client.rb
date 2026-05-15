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
      Quonfig::InternalLogger.user_logger = @options.logger if @options.logger
      @global_context = build_initial_global_context(@options)
      @instance_hash = SecureRandom.uuid
      @store = store || Quonfig::ConfigStore.new
      @evaluator = Quonfig::Evaluator.new(@store, env_id: @options.environment)
      @resolver = Quonfig::Resolver.new(@store, @evaluator)
      @semantic_logger_filters = {}
      @sse_client = nil
      @poll_supervisor = nil
      @stopped = false
      @telemetry_reporter = nil
      @state_mutex = Mutex.new
      @last_successful_refresh = nil
      @sse_state = :idle
      @sse_ever_connected = false
      @fallback_engage_timer = nil

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

    # ---- Details getters ----------------------------------------------
    #
    # Mirrors the typed getters above but returns a +Quonfig::EvaluationDetails+
    # carrying the OpenFeature-aligned resolution +reason+ ("STATIC",
    # "TARGETING_MATCH", "SPLIT", "DEFAULT", or "ERROR") plus an
    # +error_code+/+error_message+ on the error path. These methods never
    # raise — exceptions are caught and rendered as ERROR details.

    def get_bool_details(key, context: NO_DEFAULT_PROVIDED)
      evaluate_details(key, :bool, context)
    end

    def get_string_details(key, context: NO_DEFAULT_PROVIDED)
      evaluate_details(key, String, context)
    end

    def get_int_details(key, context: NO_DEFAULT_PROVIDED)
      evaluate_details(key, Integer, context)
    end

    def get_float_details(key, context: NO_DEFAULT_PROVIDED)
      evaluate_details(key, Float, context)
    end

    def get_string_list_details(key, context: NO_DEFAULT_PROVIDED)
      evaluate_details(key, :string_list, context)
    end

    def get_json_details(key, context: NO_DEFAULT_PROVIDED)
      evaluate_details(key, :json, context)
    end

    def enabled?(feature_name, jit_context = NO_DEFAULT_PROVIDED)
      value = get(feature_name, false, jit_context)
      [true, 'true'].include?(value)
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

      cancel_fallback_engage_timer

      begin
        @poll_supervisor&.stop
      rescue StandardError => e
        LOG.debug "Error stopping poll supervisor: #{e.message}"
      end
      @poll_supervisor = nil

      begin
        @telemetry_reporter&.stop
      rescue StandardError => e
        LOG.debug "Error stopping telemetry reporter: #{e.message}"
      end
      @telemetry_reporter = nil
    end

    # quonfig_sdk_worker_restart_total counter (Tier 1 supervisor contract).
    # Layer 1 (SSE) is tracked on Quonfig::SSEConfigClient#restart_total —
    # incremented once per reconnect attempt by the SDK-owned reconnect
    # loop (qfg-35sm). Layer 2 (HTTP polling fallback) is wired through
    # Quonfig::WorkerSupervisor.
    #
    # Pass +layer:+ ('1' or '2') to read a single layer; default returns the
    # sum across both layers so the chaos harness (and operators) can pull
    # per-layer values explicitly while preserving the previous single-number
    # diagnostic surface.
    def worker_restart_total(layer: nil)
      case layer&.to_s
      when '1' then sse_restart_total
      when '2' then poll_restart_total
      else          sse_restart_total + poll_restart_total
      end
    end

    # Wall-clock time of the last installed envelope (any source: datadir,
    # initial HTTP fetch, SSE, or polling fallback). +nil+ before the first
    # install. Preserved after +stop+.
    #
    # **Diagnostic only.** Do NOT wire this into a Kubernetes liveness probe
    # — a transient network blip will trip any freshness threshold and cause
    # a rolling restart cascade. See the README "Diagnostic health signals"
    # section.
    #
    # Contract: integration-test-data/chaos/supervisor-test-contract.md (Test 6).
    def last_successful_refresh
      @state_mutex.synchronize { @last_successful_refresh }
    end

    # Aggregate connection state. Returns one of:
    #
    # - +:initializing+ — no envelope has been installed and SSE is not yet
    #   connected.
    # - +:connected+ — SSE is live, or the SDK is delivering configs from a
    #   loaded envelope (datadir mode or post-initial-fetch with no SSE).
    # - +:disconnected+ — +stop+ was called, or SSE errored and no fallback
    #   poller is active.
    # - +:falling_back+ — the Layer 2 HTTP polling supervisor is alive and
    #   serving as the active update channel.
    #
    # **Diagnostic only.** Do NOT wire this into a Kubernetes liveness probe
    # — see the README "Diagnostic health signals" section.
    #
    # Contract: integration-test-data/chaos/supervisor-test-contract.md (Test 6).
    def connection_state
      @state_mutex.synchronize do
        next :disconnected if @stopped
        next :falling_back if @poll_supervisor&.alive?
        next :connected if @sse_state == :connected
        next :disconnected if @sse_state == :error

        # No SSE state change yet: state is driven by whether any envelope
        # has been installed (datadir / initial fetch).
        @last_successful_refresh.nil? ? :initializing : :connected
      end
    end

    def fork
      self.class.new(@options.for_fork)
    end

    def inspect
      "#<Quonfig::Client:#{object_id} environment=#{@options.environment.inspect}>"
    end

    private

    # Stamp +last_successful_refresh+ at install time. Called by every code
    # path that hands an envelope to the cache: datadir load, initial HTTP
    # fetch, SSE event apply, and polling worker fetch.
    def record_refresh!
      @state_mutex.synchronize { @last_successful_refresh = Time.now.utc }
    end

    def sse_restart_total
      sse = @sse_client
      return 0 if sse.nil?
      return 0 unless sse.respond_to?(:restart_total)

      sse.restart_total.to_i
    end

    def poll_restart_total
      sup = @poll_supervisor
      return 0 if sup.nil?
      return 0 unless sup.respond_to?(:worker_restart_total)

      sup.worker_restart_total.to_i
    end

    # Drive the SSE-side of the connection_state machine. The SSE client
    # invokes this on connect/error edges; tests call it directly via +send+.
    # Documented values: :idle, :connecting, :connected, :error.
    #
    # Also drives the Layer 2 fallback poller's engage/disengage:
    # - :connected clears any pending engage timer and stops an active
    #   fallback poller (SSE recovered, drop the second channel).
    # - :error before any successful connect engages immediately
    #   (initial-fail path).
    # - :error after a successful connect schedules a 2x-poll-interval
    #   grace timer; the timer engages if SSE has not recovered by then.
    #   Mirrors sdk-python's `_handle_sse_state_change` and sdk-node's
    #   `fallbackPollerActive` engagement behavior. (qfg-47c2.26)
    # Stable callable handed to Quonfig::SSEConfigClient so its +on_error+
    # block can drive @sse_state -> :error on a mid-run socket drop. Without
    # this wiring, +connection_state+ would stay +:connected+ after a
    # disconnect and customers composing staleness checks would see stale
    # data. (qfg-47c2.27)
    def sse_error_callback
      @sse_error_callback ||= ->(error) { handle_sse_error(error) }
    end

    def handle_sse_error(_error)
      handle_sse_state_change(:error)
    end

    def handle_sse_state_change(new_state)
      state = new_state.to_sym
      ever_connected = @state_mutex.synchronize do
        @sse_state = state
        @sse_ever_connected = true if state == :connected
        @sse_ever_connected
      end

      return unless @options.respond_to?(:enable_polling) && @options.enable_polling
      return if @stopped

      case state
      when :connected
        cancel_fallback_engage_timer
        stop_fallback_poller('sse-recovered')
      when :error
        if ever_connected
          schedule_fallback_engage
        else
          start_polling
        end
      end
    end

    def cancel_fallback_engage_timer
      timer = @state_mutex.synchronize do
        t = @fallback_engage_timer
        @fallback_engage_timer = nil
        t
      end
      timer&.kill if timer&.alive?
    end

    def stop_fallback_poller(reason)
      supervisor = @state_mutex.synchronize do
        s = @poll_supervisor
        @poll_supervisor = nil
        s
      end
      return if supervisor.nil?

      begin
        supervisor.stop
        LOG.debug "[quonfig] Layer 2 fallback poller stopped (reason=#{reason})"
      rescue StandardError => e
        LOG.debug "Error stopping fallback poller: #{e.message}"
      end
    end

    # Schedule a 2*poll_interval grace timer after a connected->error edge.
    # If SSE recovers before the timer fires, +cancel_fallback_engage_timer+
    # tears it down. Idempotent — does nothing if a timer is already pending
    # or the supervisor is already alive.
    def schedule_fallback_engage
      poll_interval = @options.respond_to?(:poll_interval) && @options.poll_interval ? @options.poll_interval : 60
      return if poll_interval <= 0

      grace_seconds = poll_interval * 2.0

      @state_mutex.synchronize do
        return if @fallback_engage_timer&.alive?
        return if @poll_supervisor&.alive?
        return if @stopped

        @fallback_engage_timer = Thread.new do
          Thread.current.report_on_exception = false
          sleep grace_seconds
          @state_mutex.synchronize { @fallback_engage_timer = nil }
          start_polling unless @stopped
        end
      end
    end

    # Construct and start the telemetry reporter if the options permit it.
    # The reporter runs on a background thread and periodically POSTs
    # context-shape and example-context batches to +telemetry_destination+.
    def initialize_telemetry
      shape_aggregator = nil
      example_aggregator = nil
      summaries_aggregator = nil

      if @options.collect_max_shapes.to_i.positive?
        shape_aggregator = Quonfig::Telemetry::ContextShapeAggregator.new(
          max_shapes: @options.collect_max_shapes
        )
      end

      if @options.collect_max_example_contexts.to_i.positive?
        example_aggregator = Quonfig::Telemetry::ExampleContextsAggregator.new(
          max_contexts: @options.collect_max_example_contexts
        )
      end

      if @options.collect_max_evaluation_summaries.to_i.positive?
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
      record_refresh!
    end

    # Initialize network mode: sync HTTP fetch (bounded by
    # initialization_timeout_sec) then start SSE + polling as requested.
    def initialize_network_mode
      raise Quonfig::Errors::InvalidSdkKeyError, @options.sdk_key if @options.sdk_key.nil? || @options.sdk_key.to_s.strip.empty?

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

      if result == :failed
        handle_init_failure(RuntimeError.new('Config fetch failed against all api_urls'))
      else
        record_refresh!
      end
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

      @sse_client = Quonfig::SSEConfigClient.new(
        @options,
        @config_loader,
        nil,
        nil,
        on_error: sse_error_callback
      )
      @sse_client.start do |envelope, _event, _source|
        next if @stopped

        begin
          @config_loader.apply_envelope(envelope)
          handle_sse_state_change(:connected)
          record_refresh!
        rescue StandardError => e
          LOG.warn "[quonfig] Error applying SSE envelope: #{e.message}"
          next
        end
        notify_on_update_callback
      end
      true
    rescue StandardError => e
      LOG.warn "[quonfig] SSE start failed: #{e.message}"
      @sse_client = nil
      handle_sse_state_change(:error)
      false
    end

    def start_polling
      return if @stopped
      return if @poll_supervisor&.alive?

      poll_interval = @options.respond_to?(:poll_interval) && @options.poll_interval ? @options.poll_interval : 60
      return if poll_interval <= 0

      stopped_ref = -> { @stopped }
      worker = lambda do |notify_delivered|
        loop do
          break if stopped_ref.call

          sleep poll_interval
          break if stopped_ref.call

          @config_loader.fetch!
          record_refresh!
          notify_delivered.call
          notify_on_update_callback
        end
      end

      supervisor = Quonfig::WorkerSupervisor.new(
        name: 'poll', layer: '2', worker: worker
      )
      @state_mutex.synchronize { @poll_supervisor = supervisor }
      supervisor.start
    end

    # Invoke the customer-supplied on_update callback under a rescue. A raise
    # here is the customer's bug, but it must NOT take down the SSE listener
    # or polling supervisor. Log at ERROR with a message containing
    # "onConfigUpdate callback" so chaos scenario 10's
    # sdkLog('error', /callback|onConfigUpdate/i) assertion matches and so
    # the message is distinguishable from internal envelope-apply errors
    # (qfg-47c2.30).
    def notify_on_update_callback
      cb = @on_update
      return unless cb

      begin
        cb.call
      rescue StandardError => e
        LOG.error "[quonfig] onConfigUpdate callback raised: #{e.class}: #{e.message}"
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
        merged[name] = if merged[name].is_a?(Hash) && ctx.is_a?(Hash)
                         merged[name].merge(ctx)
                       else
                         ctx.is_a?(Hash) ? ctx.dup : ctx
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

      raise Quonfig::Errors::MissingDefaultError, key if @options.on_no_default == Quonfig::Options::ON_NO_DEFAULT::RAISE

      nil
    end

    # Build a Quonfig::EvaluationDetails for +key+, evaluated against the
    # caller's context, after coercing/checking +expected_type+. Never
    # raises; all exceptions become ERROR details.
    def evaluate_details(key, expected_type, context)
      jit = context == NO_DEFAULT_PROVIDED ? nil : context
      ctx = build_context(jit)
      record_context_for_telemetry(ctx)

      result =
        begin
          @resolver.get(key, ctx)
        rescue Quonfig::Errors::MissingDefaultError => e
          return Quonfig::EvaluationDetails.new(
            value: nil,
            reason: Quonfig::EvaluationDetails::REASON_ERROR,
            error_code: Quonfig::EvaluationDetails::ERROR_FLAG_NOT_FOUND,
            error_message: e.message,
            variant: build_variant(Quonfig::EvaluationDetails::REASON_ERROR, nil, nil),
            flag_metadata: build_flag_metadata(nil, nil, nil, nil, nil)
          )
        end

      if result.nil?
        return Quonfig::EvaluationDetails.new(
          value: nil,
          reason: Quonfig::EvaluationDetails::REASON_DEFAULT,
          variant: build_variant(Quonfig::EvaluationDetails::REASON_DEFAULT, nil, nil),
          flag_metadata: build_flag_metadata(nil, nil, nil, nil, nil)
        )
      end

      record_evaluation_for_telemetry(result)

      config_id = result.config&.dig('id') || result.config&.dig(:id)
      config_type = result.config&.dig('type') || result.config&.dig(:type)
      raw_value = result.unwrapped_value

      begin
        coerced = coerce_and_check(key, raw_value, expected_type) unless raw_value.nil?
      rescue Quonfig::Errors::TypeMismatchError => e
        return Quonfig::EvaluationDetails.new(
          value: nil,
          reason: Quonfig::EvaluationDetails::REASON_ERROR,
          error_code: Quonfig::EvaluationDetails::ERROR_TYPE_MISMATCH,
          error_message: e.message,
          variant: build_variant(Quonfig::EvaluationDetails::REASON_ERROR, nil, nil),
          flag_metadata: build_flag_metadata(config_id, config_type, nil, nil, nil)
        )
      end

      reason = result.of_reason
      Quonfig::EvaluationDetails.new(
        value: coerced,
        reason: reason,
        variant: build_variant(reason, result.rule_index, result.weighted_value_index),
        flag_metadata: build_flag_metadata(
          config_id, config_type, result.rule_index, result.weighted_value_index, reason
        )
      )
    rescue StandardError => e
      Quonfig::EvaluationDetails.new(
        value: nil,
        reason: Quonfig::EvaluationDetails::REASON_ERROR,
        error_code: Quonfig::EvaluationDetails::ERROR_GENERAL,
        error_message: e.message,
        variant: build_variant(Quonfig::EvaluationDetails::REASON_ERROR, nil, nil),
        flag_metadata: build_flag_metadata(nil, nil, nil, nil, nil)
      )
    end

    # Build the variant string per the cross-SDK spec
    # (project/plans/openfeature-resolution-details.md §2).
    def build_variant(reason, rule_index, weighted_value_index)
      case reason
      when Quonfig::EvaluationDetails::REASON_STATIC
        'static'
      when Quonfig::EvaluationDetails::REASON_TARGETING_MATCH
        "targeting:#{rule_index || 0}"
      when Quonfig::EvaluationDetails::REASON_SPLIT
        "split:#{weighted_value_index || 0}"
      else
        'default'
      end
    end

    # Build the flag_metadata hash per the cross-SDK spec
    # (project/plans/openfeature-resolution-details.md §3) using Ruby's
    # snake_case keys and the wire's snake_case config_type values.
    def build_flag_metadata(config_id, config_type, rule_index, weighted_value_index, reason)
      md = {}
      md['config_id'] = config_id if config_id
      md['config_type'] = config_type if config_type
      env = @options.environment
      md['environment'] = env if env && !env.empty?
      if rule_index && rule_index >= 0 &&
         [Quonfig::EvaluationDetails::REASON_TARGETING_MATCH, Quonfig::EvaluationDetails::REASON_SPLIT].include?(reason)
        md['rule_index'] = rule_index
      end
      md['weighted_value_index'] = weighted_value_index if weighted_value_index && reason == Quonfig::EvaluationDetails::REASON_SPLIT
      md
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
        raise Quonfig::Errors::TypeMismatchError.new(key, 'Boolean', value) unless [true, false].include?(value)

        value
      when :string_list
        arr = value.is_a?(Array) ? value : nil
        raise Quonfig::Errors::TypeMismatchError.new(key, 'Array<String>', value) unless arr&.all?(String)

        arr
      when :duration
        return value.to_i if value.is_a?(Numeric)
        return (Quonfig::Duration.parse(value) * 1000).to_i if value.is_a?(String)

        raise Quonfig::Errors::TypeMismatchError.new(key, 'ISO-8601 Duration', value)
      when :json
        # JSON values are returned as-is (Hash, Array, or scalar from the wire).
        value
      when Class
        raise Quonfig::Errors::TypeMismatchError.new(key, "expected #{expected_type}", value) unless value.is_a?(expected_type)

        value
      else
        value
      end
    end
  end
end
