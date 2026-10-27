# frozen_string_literal: true

require 'json'
require 'timeout'
require 'set'

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

    # Errors that make a read of a present key fail (qfg-zvyy). Each one is
    # handled by #failed_read: the caller's default, nil, or the error.
    READ_FAILURES = [
      Quonfig::Errors::TypeMismatchError,
      Quonfig::Errors::EnvVarParseError,
      Quonfig::Errors::MissingEnvVarError,
      Quonfig::Errors::DecryptionError
    ].freeze

    # Largest integer a double holds exactly: +/-(2^53-1), the bound the
    # cross-SDK contract (and cli verify) uses for a double -> int read.
    MAX_SAFE_INTEGER = (2**53) - 1

    # Declared value type each typed getter reads. The only conversions are
    # between numbers, and only when exact (see #typed_number).
    ACCEPTED_TYPES = {
      String => %w[string log_level],
      Integer => %w[int double],
      Float => %w[double int],
      bool: %w[bool],
      string_list: %w[string_list],
      json: %w[json],
      duration: %w[duration]
    }.freeze

    TYPE_NAMES = {
      String => 'String',
      Integer => 'Integer',
      Float => 'Float',
      bool: 'Boolean',
      string_list: 'Array<String>',
      json: 'JSON',
      duration: 'ISO-8601 Duration'
    }.freeze
    private_constant :READ_FAILURES, :MAX_SAFE_INTEGER, :ACCEPTED_TYPES, :TYPE_NAMES

    # The +callback+ label values of quonfig_sdk_callback_errors_total
    # (supervisor contract). sdk-ruby has no public connection-state callback,
    # so +on_connection_state_change+ stays 0; it is listed so a reader of
    # either name gets the contract's answer.
    CALLBACK_NAMES = %w[on_config_update on_connection_state_change].freeze

    # Init fetch loop cadence (qfg-9p4i.10; init-failure design B.3, C).
    INIT_PROGRESS_EVERY_S = 5
    INIT_WAIT_PROGRESS_EVERY_S = 30
    INIT_BACKOFF_CAP_S = 30.0
    private_constant :INIT_PROGRESS_EVERY_S, :INIT_WAIT_PROGRESS_EVERY_S, :INIT_BACKOFF_CAP_S

    # Auth-failed probe period bounds, rule R3 (qfg-goi1.10.26).
    AUTH_PROBE_MIN_SECONDS = 150.0
    AUTH_PROBE_MAX_SECONDS = 300.0

    # qfg-ryov: instance registry for the Process._fork hook. Every live
    # Client is tracked here so the hook can fan out after_fork_in_child
    # across all of them without the customer needing to name a specific
    # instance. ObjectSpace::WeakMap means a Client that goes out of scope is
    # GC'd without leaking through this registry. Stopped Clients stay in the
    # registry until GC; after_fork_in_child early-returns on +@stopped+ so a
    # stopped instance is effectively a no-op. (We don't use WeakMap#delete
    # because it was added in Ruby 3.3 and the matrix still includes 3.2.)
    #
    # The registry is read in the CHILD only (qfg-lv4n.1) — the hook does
    # nothing on the parent side, so no lock is taken across the syscall.
    @instances = ObjectSpace::WeakMap.new
    @instances_mutex = Mutex.new

    class << self
      # Iterate live Client instances. Used by Quonfig::ForkSafety.
      def each_instance(&block)
        @instances_mutex.synchronize { @instances.keys }.each(&block)
      end

      def register_instance(client)
        @instances_mutex.synchronize { @instances[client] = true }
      end
    end

    attr_reader :options, :instance_hash, :telemetry_reporter

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
      warn_on_init_failure_spelling(@options)
      @global_context = build_initial_global_context(@options)
      @instance_hash = SecureRandom.uuid
      @store = store || Quonfig::ConfigStore.new
      @evaluator = Quonfig::Evaluator.new(@store, env_id: @options.environment)
      @resolver = Quonfig::Resolver.new(@store, @evaluator)
      @semantic_logger_filters = {}
      # Keys already warned about for a failed read: a wrong-type value, a
      # malformed value, an unset ENV_VAR or a decryption failure, plus
      # enabled? returning false for a missing key (qfg-2agi.10, qfg-zvyy).
      # One WARN per key per client.
      @read_failure_warned = Set.new
      @read_failure_mutex = Mutex.new
      @sse_client = nil
      @poll_supervisor = nil
      @stopped = false
      @telemetry_reporter = nil
      # Shared failover-telemetry aggregator (qfg-41nh.18). Created once and
      # shared between the ConfigLoader (which records hedge-fired /
      # guard-rejected / resolved-from at the failover call sites) and the
      # TelemetryReporter (which drains it on each flush). Created before the
      # ConfigLoader so the initial HTTP fetch — often the ONLY HTTP fetch when
      # SSE is healthy — is captured. Recording is a per-config-refresh mutex +
      # increment (negligible); nothing is EMITTED unless telemetry is enabled
      # (the reporter, which owns the drain, only starts then). Survives fork:
      # the pre-fork stop drains it, the child's rebuilt reporter drains onward.
      @failover_aggregator = Quonfig::Telemetry::FailoverAggregator.new
      @state_mutex = Mutex.new
      @last_successful_refresh = nil
      @sse_state = :idle
      @sse_ever_connected = false
      @fallback_engage_timer = nil
      # quonfig_sdk_callback_errors_total{callback} (supervisor contract Test 5,
      # qfg-6vno.6.1). Guarded by @state_mutex. See #callback_errors_total.
      @callback_errors = CALLBACK_NAMES.to_h { |name| [name, 0] }
      # Auth-failed regime (rule R2-R4, qfg-goi1.10.26). Set by the poller's
      # fetch cycle on entry, cleared by the first accepted probe. While set:
      # no SSE, no polling, one probe per [150s, 300s]. Read by
      # #terminal_failure? and #connection_state.
      @auth_failed = false
      # The process that owns this client's threads, sockets, and store.
      # Re-stamped when a child takes ownership in #rebuild_in_child!. A pid
      # mismatch is PROOF that we are looking at a fork(2) child, which is
      # what makes #owned_by_this_process? exact. See that method for why
      # thread liveness could not answer the question.
      @owner_pid = Process.pid
      # Post-fork lazy re-initialization (qfg-lv4n.1). Set by
      # +after_fork_in_child+; cleared by the first use of the client in the
      # child. See #ensure_initialized_after_fork.
      @fork_rebuild_pending = false
      @fork_rebuild_mutex = Mutex.new
      # The thread currently running the rebuild, so a re-entrant read (a
      # SemanticLoggerFilter or stdlib formatter that calls +get+ from inside
      # the rebuild's own logging) does not deadlock on the non-reentrant
      # Mutex above.
      @fork_rebuild_owner = nil
      # Sticky init error under +on_init_failure: :raise+ (see
      # #raise_sticky_fork_init_error).
      @fork_rebuild_error = nil

      # If the caller injected a store, we're in test/bootstrap mode; skip I/O.
      return if store

      if @options.datadir
        load_datadir_into_store
        start_datadir_watcher if @options.data_dir_auto_reload
      else
        initialize_network_mode
      end

      initialize_telemetry

      # Register only for non-store-injected clients (a caller-supplied store
      # is the test/bootstrap path; the fork hook does not apply there).
      # Always the base class registry: a subclass has no @instances of its own.
      Quonfig::Client.register_instance(self) unless store
    end

    # ---- Lookup --------------------------------------------------------

    # The config's value, untyped.
    #
    # A missing key returns +default+, or applies +on_no_default+ (nil under
    # :return_nil, MissingDefaultError under :raise). A read that fails (an
    # unset ENV_VAR, a decryption failure, a malformed stored or ENV_VAR
    # value) follows the typed-getter contract (qfg-zvyy): +default+ when one
    # is given, otherwise nil under :return_nil or the error itself under
    # :raise, and one WARN per key either way.
    def get(key, default = NO_DEFAULT_PROVIDED, jit_context = NO_DEFAULT_PROVIDED)
      ensure_initialized_after_fork
      ctx = build_context(jit_context)
      record_context_for_telemetry(ctx)
      begin
        result = resolve_for_read(key, ctx)
        return handle_missing(key, default) if result.nil?

        record_evaluation_for_telemetry(result)
        unwrap_for_read(result)
      rescue *READ_FAILURES => e
        failed_read(key, default, e)
      end
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

    # Integer milliseconds for a duration config (qfg-2agi.10). Values follow
    # the shared grammar (Quonfig::Duration); ms are rounded half up on both
    # the stored and the ENV_VAR path. A config whose valueType is not
    # duration, or a malformed duration, is a failed read under the
    # typed-getter contract (see #typed_get).
    def get_duration(key, default: NO_DEFAULT_PROVIDED, context: NO_DEFAULT_PROVIDED)
      typed_get(key, :duration, default: default, context: context)
    end

    def get_json(key, default: NO_DEFAULT_PROVIDED, context: NO_DEFAULT_PROVIDED)
      typed_get(key, :json, default: default, context: context)
    end

    # Like +get+, but never applies the +on_no_default+ policy (qfg-2agi.27):
    #
    # - A missing key (or a config with no matching value) returns +default:+
    #   when one is given and otherwise raises MissingDefaultError, even
    #   under on_no_default: :return_nil.
    # - A config provided by an unset ENV_VAR raises MissingEnvVarError; an
    #   ENV_VAR value that cannot be coerced to the config's type raises
    #   EnvVarParseError; a decryption failure raises DecryptionError.
    # - A malformed stored duration raises EnvVarParseError (a given
    #   +default:+ is not applied; it only covers a missing key).
    def get_or_raise(key, default: NO_DEFAULT_PROVIDED, context: NO_DEFAULT_PROVIDED)
      ensure_initialized_after_fork
      ctx = build_context(context)
      record_context_for_telemetry(ctx)
      result =
        begin
          @resolver.get(key, ctx)
        rescue Quonfig::Errors::MissingDefaultError
          nil
        end
      if result.nil?
        raise Quonfig::Errors::MissingDefaultError, key if default == NO_DEFAULT_PROVIDED

        return default
      end

      record_evaluation_for_telemetry(result)
      unwrap_for_read(result)
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

    # Integer milliseconds in +value+ (qfg-2agi.27). A config whose valueType
    # is not duration is ERROR / TYPE_MISMATCH; a malformed value (stored or
    # ENV_VAR) is ERROR with a nil value.
    def get_duration_details(key, context: NO_DEFAULT_PROVIDED)
      evaluate_details(key, :duration, context)
    end

    # True only when the flag resolves to the bool +true+. Never raises
    # (qfg-zvyy): a missing key, a flag with no matching rule, a value that is
    # not a bool (a stored string "true" included) or any resolution error
    # returns false and logs one WARN per key.
    def enabled?(feature_name, jit_context = NO_DEFAULT_PROVIDED)
      ensure_initialized_after_fork
      begin
        ctx = build_context(jit_context)
        record_context_for_telemetry(ctx)
        result = resolve_for_read(feature_name, ctx)
        if result.nil?
          warn_read_failure(feature_name, 'missing key or no matching rule; enabled? returns false')
          return false
        end

        record_evaluation_for_telemetry(result)
        typed_value(feature_name, result, :bool) == true
      rescue StandardError => e
        warn_read_failure(feature_name, "#{e.message}; enabled? returns false")
        false
      end
    end

    def defined?(key)
      ensure_initialized_after_fork
      !@store.get(key).nil?
    end

    def keys
      ensure_initialized_after_fork
      @store.keys
    end

    # ---- Context binding ----------------------------------------------

    # Bind +properties+ as a context. With a block, yields a
    # {Quonfig::BoundClient} and returns the block's value. Without a block,
    # returns the BoundClient directly.
    #
    # qfg-e0kk: kept as a deprecated alias of {#with_context}. The two methods
    # have always been runtime-identical; sdk-1.0 unifies on +with_context+
    # across all SDKs. No runtime warning is emitted (Prefab-fork lineage,
    # heavy customer usage). Slated for removal in 2.0.0.
    #
    # @deprecated Use {#with_context} instead.
    def in_context(properties, &block)
      with_context(properties, &block)
    end

    # Bind +properties+ as a context. With a block, yields a
    # {Quonfig::BoundClient} and returns the block's value. Without a block,
    # returns the BoundClient directly — useful for passing a context-bound
    # handle down the stack.
    def with_context(properties)
      bound = Quonfig::BoundClient.new(self, properties)
      block_given? ? yield(bound) : bound
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
      # Order matters (qfg-lv4n.1 D5). The flag goes up BEFORE we queue for
      # the rebuild lock, so a post-fork rebuild already in flight sees it and
      # skips starting an update channel and a telemetry reporter at all —
      # otherwise it builds an SSE worker after we have finished tearing down
      # and nothing is left holding a reference to close it.
      @stopped = true
      # A child that never used the client must be able to stop it without
      # paying for a re-initialization it never asked for.
      @fork_rebuild_pending = false
      @fork_rebuild_error = nil

      # ...and the teardown itself is serialized against the rebuild, so it
      # can never interleave with component construction. Re-entrancy: if the
      # rebuild is what called `stop` (a customer on_update/logger hook), this
      # thread already holds the lock.
      if @fork_rebuild_owner == Thread.current
        tear_down_threaded_components!
      else
        @fork_rebuild_mutex.synchronize { tear_down_threaded_components! }
      end
    end

    # @deprecated Since 1.4.0 the +Process._fork+ hook NO LONGER CALLS THIS.
    #   A fork must not disturb the process that forked: the parent keeps its
    #   SSE stream, its poller, and its telemetry reporter, and keeps serving
    #   live config (qfg-lv4n.1). This method is retained for semver and for
    #   the Ruby 3.0 manual-wiring path, where a customer who genuinely wants
    #   the parent torn down before a fork can still call it. Prefer +stop+
    #   if you want the client dead.
    #
    # Closes the SSE worker, polling supervisor, telemetry reporter, datadir
    # watcher, and any fallback-engage timer. Idempotent. Does NOT set
    # +@stopped+, so +after_fork_in_child+ can still rebuild.
    def before_fork_in_parent
      return if @stopped

      tear_down_threaded_components!
    end

    # Post-fork hook, run IN THE CHILD ONLY (see Quonfig::ForkSafety).
    #
    # Ruby threads do not survive fork(2), so everything threaded the child
    # inherited is a dead reference. The child drops those references and
    # rebuilds from scratch — matching Reforge's +Reforge.fork+, which simply
    # constructs a brand-new client and lets the inherited one be collected.
    #
    # Two things we deliberately do NOT do to the inherited objects:
    #
    # * **Never close the inherited SSE socket.** fork(2) duplicates the fd,
    #   so the child's copy points at the connection the PARENT is still
    #   streaming on. Closing a TLS socket writes a +close_notify+ alert onto
    #   that shared connection and kills the parent's stream. Dropping the
    #   reference leaves the parent's fd untouched.
    # * **Never join an inherited thread.** The thread does not exist in the
    #   child, so a +join+/+stop+ that waits on it blocks forever (see
    #   LaunchDarkly ruby-server-sdk PR #430: "close blocks forever, because
    #   EventProcessor#stop waits for a dispatcher thread that does not
    #   exist").
    #
    # No-op if the client was already stopped — the customer asked for it to
    # be dead, and a fork must not resurrect it.
    #
    # Also a no-op in the process that OWNS the client, i.e. the PARENT —
    # decided by a pid stamp, not by whether anything looks alive. Releases
    # 1.0-1.3 documented calling this in the parent as the workaround for the
    # parent going dark after a fork; on 1.4.0+ such a call would orphan the
    # parent's live components and zero its store, so it is ignored (one
    # debug line). See #owned_by_this_process?.
    #
    # The hook does NO I/O: no fetch, no socket, no thread. It throws away
    # everything the child inherited — including the parent's config snapshot
    # — and arms a flag. The child re-initializes on its FIRST use of the
    # client (see #ensure_initialized_after_fork), exactly like a newly
    # constructed client would. A child that never uses the client, which is
    # most of them in a `Parallel.map` batch, costs nothing at all.
    def after_fork_in_child
      return if @stopped
      return if owned_by_this_process?

      # The inherited Mutexes may be held by threads that no longer exist.
      # Only this thread exists in a fresh child, so swapping them is safe.
      @state_mutex = Mutex.new
      @fork_rebuild_mutex = Mutex.new
      @fork_rebuild_owner = nil
      @fork_rebuild_error = nil
      drop_inherited_threaded_components!

      # SSE state machine carries flags that describe the PARENT's session
      # (it had connected, it had errored, ...). None of them apply here.
      @sse_state = :idle
      @sse_ever_connected = false
      @auth_failed = false
      @sse_error_callback = nil

      # A client that never finished network init has nothing to rebuild.
      return if @config_loader.nil? && !@options.datadir

      # A brand-new, EMPTY store. The child must not evaluate from whatever
      # snapshot the parent happened to hold at the instant of the fork: it
      # fetches (or loads) its own on first use.
      reset_store_in_child!

      # A fresh instance hash (qfg-xcym). `@instance_hash` identifies this
      # SDK instance in every telemetry payload, and app-quonfig's Debugger
      # groups SDK last-seen by it — so a child that keeps the parent's hash
      # collapses an 8-worker Puma cluster into ONE row with the parent's and
      # the children's windows interleaved. Reforge does not have this
      # problem: `Reforge.fork` builds a whole new Client, which mints its
      # own. This MUST run before +rebuild_aggregators_in_child!+: the
      # reporter captures the hash at construction, so minting after the
      # rebuild would leave the child POSTing under the parent's identity.
      # The parent's hash is untouched — the hook never runs there.
      @instance_hash = SecureRandom.uuid

      # Fresh aggregators. The parent flushes its own copy; a child that
      # flushed inherited data would double-report it. The reporter is BUILT
      # here (so the child's config loader points at the child's failover
      # aggregator) but NOT started — starting it is I/O, and that waits for
      # first use.
      rebuild_aggregators_in_child!

      @forked_in_pid = Process.pid
      @fork_rebuild_pending = true
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

    # quonfig_sdk_callback_errors_total counter (supervisor contract Test 5,
    # qfg-6vno.6.1). Counts each call of your +on_update+ block that raised a
    # StandardError the SDK caught and logged at ERROR. Such a raise is not a
    # worker restart: #worker_restart_total does not change, the stream keeps
    # running, and the next update still reaches your block.
    #
    # Pass +callback:+ ('on_config_update' or 'on_connection_state_change',
    # String or Symbol) for one label; the default returns the sum. sdk-ruby
    # has no connection-state callback, so 'on_connection_state_change' is
    # always 0. An unknown name raises ArgumentError. Starts at 0 when the
    # client is built.
    def callback_errors_total(callback: nil)
      @state_mutex.synchronize do
        next @callback_errors.values.sum if callback.nil?

        name = callback.to_s
        raise ArgumentError, "unknown callback #{callback.inspect}; expected one of #{CALLBACK_NAMES.join(', ')}" unless
          @callback_errors.key?(name)

        @callback_errors[name]
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
        # Forked, not yet used: nothing has been fetched and nothing is
        # running. Saying so is the honest answer, and a diagnostic must not
        # be what triggers a blocking fetch.
        next :initializing if @fork_rebuild_pending
        # Auth-failed is not a state of its own (R6): SSE and the poller are
        # off, so the client is disconnected, never falling_back.
        next :disconnected if @auth_failed
        next :falling_back if @poll_supervisor&.alive?
        # Liveness beats the stored flag (qfg-lv4n.1). A client whose SSE
        # session was torn down keeps a stale @sse_state; answering
        # :connected off that flag is how a dark client reported healthy for
        # 13 days. If this client is supposed to have a live SSE worker and
        # does not, it is disconnected — whatever the flag says.
        next :disconnected if sse_channel_expected? && !sse_worker_alive?
        next :connected if @sse_state == :connected
        next :disconnected if @sse_state == :error

        # No SSE state change yet: state is driven by whether any envelope
        # has been installed (datadir / initial fetch).
        @last_successful_refresh.nil? ? :initializing : :connected
      end
    end

    # ---- Failover + canonical-ordering diagnostics (qfg-7h5d.1.9) ------
    #
    # Read-only signals surfaced for the failover/ordering chaos probe and for
    # operators. Like #connection_state / #last_successful_refresh these are
    # DIAGNOSTIC ONLY — do not wire them into a liveness probe.

    # True once the SDK has installed at least one envelope (any source). The
    # failover scenarios assert the client reaches readiness off the secondary
    # leg inside the init budget even when the primary is refused/hung/slow.
    def ready?
      !last_successful_refresh.nil?
    end

    # Block until the client has config (see #ready?), up to +timeout_ms+ (nil
    # = no bound). Returns true once ready, false if the timeout ran out or the
    # client was stopped first (qfg-9p4i.10; init-failure design B.4). Never
    # raises for an outage: under on_init_failure: :continue this is how a
    # caller waits for the background retry to heal.
    #
    # In a forked child that has not used the client yet, this runs the
    # child's re-initialization (as any first use does) and keeps waiting if
    # that fails.
    def wait_for_ready(timeout_ms: nil)
      deadline = timeout_ms && (monotonic_now + (timeout_ms / 1000.0))
      begin
        ensure_initialized_after_fork
      rescue Quonfig::Errors::InitializationError
        nil
      end
      loop do
        return true if ready?
        return false if @stopped
        return false if deadline && monotonic_now >= deadline

        sleep WAIT_FOR_READY_POLL_S
      end
    end

    WAIT_FOR_READY_POLL_S = 0.05

    # Meta.generation of the currently-held envelope (0 before the first install
    # or when the backend does not emit a generation). Canonical ordering: an
    # established client never regresses to a lower generation.
    def held_generation
      @config_loader&.held_generation || 0
    end

    # Count of envelopes actually installed. Rejected-older and same-generation
    # snapshots do NOT bump this, so o04 can assert "no flap" via a stable count.
    def config_install_count
      @config_loader&.install_count || 0
    end

    # 'primary' / 'secondary' / '' — which config_api_urls leg produced the
    # currently-held config. Used to assert HTTP config-fetch failover (f01-f04).
    def resolved_from
      @config_loader&.resolved_from || ''
    end

    # True if the live SSE stream has ever repointed to a non-primary leg. The
    # failover epic asserts this stays false (f05): SSE does not fail over.
    def sse_failed_over_to_secondary?
      sse = @sse_client
      return false if sse.nil?
      return false unless sse.respond_to?(:failed_over_to_secondary?)

      sse.failed_over_to_secondary?
    end

    # ---- Component readers ---------------------------------------------
    #
    # Public since 1.0 and kept public for semver. Each one routes through
    # the post-fork chokepoint: in a forked child that has not been used yet
    # the raw components read an EMPTY store (+store.get+ answered nil,
    # +resolver.get+ raised MissingDefaultError), so handing them back
    # without re-initializing is handing back a component that lies
    # (qfg-lv4n.1 D6).

    # @return [Quonfig::ConfigStore] the store backing this client.
    # @note In a forked child, reading this triggers the lazy post-fork
    #   re-initialization (see #after_fork_in_child) — it can block on the
    #   child's own config fetch.
    def store
      ensure_initialized_after_fork
      @store
    end

    # @return [Quonfig::Resolver]
    # @note (see #store)
    def resolver
      ensure_initialized_after_fork
      @resolver
    end

    # @return [Quonfig::Evaluator]
    # @note (see #store)
    def evaluator
      ensure_initialized_after_fork
      @evaluator
    end

    # @return [Quonfig::ConfigLoader, nil] nil in datadir mode.
    # @note (see #store)
    def config_loader
      ensure_initialized_after_fork
      @config_loader
    end

    # A client to use in a forked child.
    #
    # On Ruby 3.1+ the +Process._fork+ hook has already prepared THIS client
    # in the child by the time any user code runs there (inherited threads
    # and store dropped, re-initialization armed for first use). A call here
    # in that child — the +on_worker_boot { Quonfig.fork }+ line the 1.0–1.3
    # README taught — therefore returns +self+: the hook already did what the
    # caller is asking for. Building a second client instead would discard
    # the prepared one and pay an eager second fetch, or, after first use,
    # leave the worker holding two live SSE streams and two reporters with
    # the first pair orphaned where +stop+ can never reach it (qfg-4t5o).
    #
    # Everywhere else — the owning process, Ruby 3.0 where there is no hook,
    # a client that was +stop+ped before the fork — this builds a fresh
    # client, which is the Ruby 3.0 manual-wiring path. The old client is
    # never stopped: on 3.0 it is the inherited one, and stopping it would
    # close the inherited socket and tear down the PARENT's stream.
    def fork
      return self if @forked_in_pid == Process.pid

      self.class.new(@options.for_fork)
    end

    def inspect
      "#<Quonfig::Client:#{object_id} environment=#{@options.environment.inspect}>"
    end

    private

    # True when THIS process is the one that owns the client — i.e. we are
    # the parent, not a fork(2) child.
    #
    # The answer is a pid comparison against the stamp taken when the client
    # was constructed (and re-taken when a child rebuilds it). A pid mismatch
    # is PROOF of a fork child; a match is proof that nobody forked.
    #
    # It deliberately does NOT ask whether any component looks alive, which
    # is what 1.4.0 shipped and what got this wrong at both ends:
    #
    # * **False negative in a real child.** +on_update+ runs on the SSE worker
    #   thread, so a customer who forks from that callback forks ON it — and
    #   the inherited +@worker.alive?+ is therefore true in the child. The
    #   child was classified as the parent, ignored the hook, served the
    #   parent's snapshot forever and reported +:connected+ (qfg-lv4n.1 E1).
    # * **False positive in a real parent.** A datadir client with
    #   auto-reload off and no SDK key has no threads and no reporter at all,
    #   so the guard let a parent-side call through and it wiped the live
    #   store (qfg-lv4n.1 E4/D4).
    #
    # The parent case is what makes a stray +after_fork_in_child+ call a
    # no-op. Releases 1.0-1.3 documented exactly that call as the workaround
    # for the parent-keeps-evaluating topology, and that code is still out
    # there: on 1.4.0+ it would orphan the live SSE worker and its stream,
    # zero the store, and stop the owner's telemetry reporter.
    def owned_by_this_process?
      return false unless @owner_pid == Process.pid

      LOG.debug '[quonfig] after_fork_in_child called in the process that OWNS the client ' \
                "(pid=#{Process.pid}); ignoring. Since 1.4.0 a fork never touches the " \
                'process that forked, and the child-side rebuild is automatic on Ruby 3.1+.'
      true
    end

    # True when this client is a network-mode client that asked for SSE, i.e.
    # one that is SUPPOSED to be holding a live stream. Datadir clients and
    # store-injected (test/bootstrap) clients never are, so their
    # +connection_state+ keeps deriving from envelope installs alone.
    def sse_channel_expected?
      return false if @options.datadir
      return false unless @options.enable_sse

      !@config_loader.nil?
    end

    # Is there an SSE worker thread actually running right now? Note this
    # stays true across a reconnect: the worker owns the retry loop, so a
    # blip does not read as "no channel".
    def sse_worker_alive?
      sse = @sse_client
      return false if sse.nil?
      return true unless sse.respond_to?(:alive?)

      sse.alive?
    end

    # Close every threaded component and drop its reference. Used by +stop+
    # (where @stopped is also flipped) and by the deprecated manual
    # +before_fork_in_parent+ (where @stopped is left alone). NOT reachable
    # from the fork hook any more — a fork never touches the process that
    # forked (qfg-lv4n.1).
    def tear_down_threaded_components!
      # The SSE state machine describes a session that no longer exists.
      # Leaving @sse_state == :connected behind is how `connection_state`
      # came to answer :connected for a client with nothing alive.
      @state_mutex.synchronize { @sse_state = :idle }

      begin
        @sse_client&.close
      rescue StandardError => e
        LOG.debug "Error closing SSE client: #{e.message}"
      end
      @sse_client = nil

      cancel_fallback_engage_timer

      # Sleep-only thread with no I/O and nothing to drain: killing it is safe.
      @not_ready_reporter&.kill
      @not_ready_reporter = nil

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

      begin
        @datadir_watcher&.stop
      rescue StandardError => e
        LOG.debug "Error stopping datadir watcher: #{e.message}"
      end
      @datadir_watcher = nil
    end

    # Drop every inherited threaded component WITHOUT closing, stopping, or
    # joining it. See the comment on +after_fork_in_child+ for why touching
    # these objects in the child is actively harmful (shared socket fds,
    # threads that do not exist). Reforge, LaunchDarkly, dd-trace-rb,
    # redis-client and connection_pool all do exactly this.
    def drop_inherited_threaded_components!
      inherited_reporter = @telemetry_reporter

      @sse_client = nil
      @poll_supervisor = nil
      @telemetry_reporter = nil
      @datadir_watcher = nil
      @fallback_engage_timer = nil
      @not_ready_reporter = nil
      @init_heal_pending = false

      # Dropping our reference is not enough for the reporter: its
      # `Kernel.at_exit { final_drain_on_exit }` closure is process-wide, it
      # was copied by fork(2), and it still holds a full copy of the PARENT's
      # un-flushed telemetry window. The reporter's own owner-pid guard is
      # what makes that closure inert (see TelemetryReporter#start); this
      # additionally makes the copied window unreachable. Neither stops,
      # closes, nor joins anything.
      begin
        inherited_reporter&.discard_inherited!
      rescue StandardError => e
        LOG.debug "Error discarding inherited telemetry reporter: #{e.message}"
      end
    end

    # Lazy post-fork re-initialization. Called from every read entry point
    # (+get+, +evaluate_details+, +defined?+, +keys+) — the flag read is a
    # plain boolean, so the steady-state cost is one comparison per lookup.
    #
    # The first caller in the child does what +Client.new+ does: its own
    # config fetch under the configured init timeout and +on_init_failure+
    # policy, then its own SSE stream (or fallback poller) and its own
    # telemetry reporter. It BLOCKS, so that first lookup already reflects
    # the child's own current config.
    #
    # +connection_state+ deliberately does NOT trigger this: a diagnostic
    # must never open a socket. It reports +:initializing+ while a rebuild is
    # pending, which is exactly what the client is.
    def ensure_initialized_after_fork
      # Hot path: two ivar reads and no lock. Both are falsy for every client
      # that has never been through a fork.
      return unless @fork_rebuild_pending || @fork_rebuild_error
      # Re-entrancy guard: a customer logger (SemanticLoggerFilter, stdlib
      # formatter) that evaluates a config from inside the rebuild would
      # otherwise deadlock on the non-reentrant Mutex. Such a call sees the
      # half-built client, which is the same thing Client.new gives a logger
      # that fires during construction.
      return if @fork_rebuild_owner == Thread.current

      run_pending_child_rebuild if @fork_rebuild_pending
      raise_sticky_fork_init_error if @fork_rebuild_error
    end

    # Run the rebuild under the lock, or block until whoever is running it is
    # done. The flag stays TRUE for the whole rebuild, which is what makes
    # every other first-use caller take the mutex and WAIT rather than sail
    # past on the unlocked fast path and evaluate against the empty store.
    def run_pending_child_rebuild
      @fork_rebuild_mutex.synchronize do
        # Lost the race: the winner already rebuilt (or `stop` disarmed us).
        return unless @fork_rebuild_pending
        return if @stopped

        @fork_rebuild_owner = Thread.current
        begin
          rebuild_in_child!
        rescue StandardError => e
          # Handled: the child gets whatever healing path its mode allows, so
          # the next lookup must not re-run the blocking fetch. (The datadir
          # recovery path may deliberately re-arm — see
          # #recover_datadir_child_after_failed_rebuild.)
          @fork_rebuild_pending = false
          handle_child_rebuild_failure(e)
        ensure
          @fork_rebuild_owner = nil
          # #rebuild_in_child! disarms the flag itself the moment the child
          # has a live path to config. Anything that escapes before that —
          # including a non-StandardError such as rack-timeout's
          # RequestTimeoutException, Ruby 3.3's Timeout::ExitException, or a
          # Thread#kill, none of which the rescue above can see — leaves the
          # flag armed so the NEXT call retries instead of leaving the child
          # dark forever (qfg-lv4n.1 D2).
          @fork_rebuild_pending = false if @stopped
        end
      end
    end

    # Under +on_init_failure: :raise+ a failed rebuild raises out of the call
    # that triggered it, exactly as +Client.new+ would — and keeps raising on
    # subsequent calls (without re-fetching) until the update channel heals
    # the store. Under +:return+ nothing is stored here and this never fires.
    def raise_sticky_fork_init_error
      err = @fork_rebuild_error
      return if err.nil?

      if ready?
        # The SSE stream (or the poller) installed an envelope: the client is
        # serving real config again, so the init failure is history.
        @fork_rebuild_error = nil
        return
      end

      raise err
    end

    # A rebuild that raised. Log it, give the child whatever healing path its
    # mode has, and honor +on_init_failure+.
    def handle_child_rebuild_failure(err)
      LOG.error "[quonfig] post-fork re-initialization failed: #{err.class}: #{err.message}"

      if @options.datadir
        recover_datadir_child_after_failed_rebuild
      else
        begin
          start_update_channel if @sse_client.nil? && @poll_supervisor.nil?
        rescue StandardError => e
          LOG.error "[quonfig] post-fork update channel failed to start: #{e.class}: #{e.message}"
        end
      end

      return unless @options.on_init_failure == Quonfig::Options::ON_INITIALIZATION_FAILURE::FAIL

      # Parity with a fresh Client.new, which raises under :fail. Stored so
      # later calls keep raising rather than re-running the fetch on every
      # lookup.
      @fork_rebuild_error = err
      raise err
    end

    # A datadir client is configured OFFLINE: it has no config loader, so
    # opening an SSE stream here dials the network on a customer who asked
    # for none and then blows up on every envelope that arrives
    # ("undefined method `apply_envelope' for nil"). The healing path for a
    # datadir child is the filesystem: start the watcher if auto-reload is on
    # so a repaired workspace is picked up, and otherwise re-arm the rebuild
    # so the next use retries the load (qfg-lv4n.1 D3).
    def recover_datadir_child_after_failed_rebuild
      begin
        start_datadir_watcher if @options.data_dir_auto_reload && @datadir_watcher.nil?
      rescue StandardError => e
        LOG.error "[quonfig] post-fork datadir watcher failed to start: #{e.class}: #{e.message}"
      end

      return unless @datadir_watcher.nil?

      @fork_rebuild_pending = true
    end

    # The child's own re-initialization, run on first use. Mirrors what
    # +Client.new+ does for this client's mode, and logs one info line so a
    # customer grepping their logs can see the SDK noticed the fork.
    def rebuild_in_child!
      # This process is taking ownership of the client. Re-stamping here is
      # what keeps #owned_by_this_process? exact for everything that follows:
      # a manual +after_fork_in_child+ in THIS child is now correctly a
      # no-op, and a grandchild forked from here is still detected by pid.
      @owner_pid = Process.pid
      components = []

      if @options.datadir
        load_datadir_into_store
        components << 'datadir'
        start_datadir_watcher if @options.data_dir_auto_reload
        components << 'datadir-watcher' if @datadir_watcher
      else
        initialize_network_mode
        components << 'config' if ready?
        components << 'sse' if @sse_client
        components << 'polling' if @poll_supervisor
      end

      # The child now has a live path to config (a stream/poller, or a loaded
      # datadir). Disarm HERE, not in the caller: everything above is
      # retryable and must stay armed if it is interrupted, and everything
      # below must never re-run the fetch or dial a second stream.
      @fork_rebuild_pending = false

      unless @stopped
        @telemetry_reporter&.start
        components << 'telemetry' if @telemetry_reporter
      end

      log_child_rebuild(components)
    end

    # A brand-new store (plus the evaluator, resolver, and config loader that
    # read it) so the child starts from nothing and installs its own envelope.
    # Two things this buys beyond "no stale config": the child's first
    # envelope is ACCEPTED rather than dropped by the reject-older guard as
    # same-generation, and a fork that lands mid-install can no longer hand
    # the child a half-written store.
    def reset_store_in_child!
      @store = Quonfig::ConfigStore.new
      @evaluator = Quonfig::Evaluator.new(@store, env_id: @options.environment)
      @resolver = Quonfig::Resolver.new(@store, @evaluator)
      @last_successful_refresh = nil
      return if @options.datadir

      @config_loader = Quonfig::ConfigLoader.new(@store, @options, failover_aggregator: @failover_aggregator)
    end

    # Replace every aggregator with a fresh, empty one so the child never
    # re-reports data the parent collected (and is still going to flush from
    # its own copy). Mirrors what a brand-new Client.new would allocate.
    def rebuild_aggregators_in_child!
      @failover_aggregator = Quonfig::Telemetry::FailoverAggregator.new
      # The ConfigLoader records hedge/guard/resolved-from at its failover
      # call sites, so it has to point at the child's aggregator too — the
      # inherited one is now the parent's private object.
      @config_loader.failover_aggregator = @failover_aggregator if @config_loader.respond_to?(:failover_aggregator=)

      # initialize_telemetry allocates fresh context/example/summaries
      # aggregators and a fresh reporter. It is NOT started here: starting the
      # reporter is I/O and a thread, and both wait for the child's first use.
      @telemetry_reporter = nil
      initialize_telemetry(start: false)
    end

    # One line, at info, so a customer can see in their logs that the SDK
    # noticed the fork and rebuilt. Deliberately not a warning: forking is
    # normal and expected.
    def log_child_rebuild(components)
      list = components.empty? ? 'none' : components.join(',')
      LOG.info "[quonfig] re-initialized after fork pid=#{Process.pid} components=#{list}"
    end

    # Stamp +last_successful_refresh+ at install time. Called by every code
    # path that hands an envelope to the cache: datadir load, initial HTTP
    # fetch, SSE event apply, and polling worker fetch.
    def record_refresh!
      healed_from = @state_mutex.synchronize do
        @last_successful_refresh = Time.now.utc
        next nil unless @init_heal_pending

        # First install after an init that continued without config. Cleared
        # under the lock so racing installers log the heal exactly once.
        @init_heal_pending = false
        @init_started_at || monotonic_now
      end
      # The section C heal line, at WARN so the filter level that saw the
      # failure also sees the recovery. Logged outside the lock.
      log_init_recovered(healed_from) if healed_from
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

    def sse_connected_callback
      @sse_connected_callback ||= -> { handle_sse_state_change(:connected) unless @stopped }
    end

    # Every SSE error, auth-class included, is an ordinary drop: SSE alone
    # never enters auth-failed (rule R2, qfg-goi1.10.26; this reverses the
    # qfg-i5xv latch). The fallback poller engages on its usual schedule and
    # its fetch cycle decides.
    def handle_sse_error(_error)
      handle_sse_state_change(:error)
    end

    def handle_sse_state_change(new_state)
      state = new_state.to_sym
      ever_connected, auth_failed = @state_mutex.synchronize do
        @sse_state = state
        @sse_ever_connected = true if state == :connected
        [@sse_ever_connected, @auth_failed]
      end

      return unless @options.respond_to?(:fallback_poll_enabled) && @options.fallback_poll_enabled
      return if @stopped
      # While auth-failed SSE is stopped; a late edge from the stream being
      # torn down changes nothing (the probe loop owns the schedule).
      return if auth_failed

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

    public

    # True while the client is auth-failed (since 1.8.0, qfg-goi1.10.26): a
    # whole config fetch cycle got no 200/304 on any leg and a 401, 403, 404
    # or 410 on the primary leg, which means the SDK key is invalid or
    # revoked. It turns true when the fallback poller's cycle (or, with
    # +enable_sse: false+, a poll) is rejected: about 120s after a mid-life
    # stream drop, at once if SSE never connected. While true, SSE and polling
    # are off and the client sends one fetch probe every 150-300s. It goes back
    # to false on the first probe that gets a valid 200 or a 304, and the
    # client resumes streaming and polling on its own; there is no need to
    # rebuild the client.
    #
    # Before 1.8.0 this latched true on the first SSE 401/403/404 for the life
    # of the client (qfg-i5xv). +connection_state+ reports +:disconnected+
    # while this is true.
    def terminal_failure?
      @state_mutex.synchronize { @auth_failed }
    end

    private

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

    # Schedule a 2*fallback_poll_interval grace timer after a connected->error
    # edge. If SSE recovers before the timer fires,
    # +cancel_fallback_engage_timer+ tears it down. Idempotent — does nothing
    # if a timer is already pending or the supervisor is already alive.
    def schedule_fallback_engage
      poll_ms = if @options.respond_to?(:fallback_poll_interval_ms) && @options.fallback_poll_interval_ms
                  @options.fallback_poll_interval_ms
                else
                  60_000
                end
      return if poll_ms <= 0

      grace_seconds = (poll_ms / 1000.0) * 2.0

      @state_mutex.synchronize do
        return if @fallback_engage_timer&.alive?
        return if @poll_supervisor&.alive?
        return if @stopped

        @fallback_engage_timer = Thread.new do
          Thread.current.report_on_exception = false
          Quonfig::Waits.sleep(:engage, grace_seconds)
          @state_mutex.synchronize { @fallback_engage_timer = nil }
          start_polling unless @stopped
        end
      end
    end

    # Construct and start the telemetry reporter if the options permit it.
    # The reporter runs on a background thread and periodically POSTs
    # context-shape and example-context batches to +telemetry_destination+.
    def initialize_telemetry(start: true)
      @telemetry_reporter = Quonfig::Telemetry::TelemetryReporter.build(
        options: @options,
        instance_hash: @instance_hash,
        failover_aggregator: @failover_aggregator
      )
      return if @telemetry_reporter.nil?
      return unless @telemetry_reporter.enabled?
      return unless start

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
        # Confidential / decryptWith values ship as the `*****<hash>` redacted
        # form, never the plaintext (qfg-2agi.15).
        selected_value: result.reportable_value.nil? ? result.unwrapped_value : result.reportable_value,
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
      apply_datadir_envelope(envelope)
    end

    # Apply a freshly loaded datadir envelope to the store. Keys that were
    # present before but missing now are deleted, so a `rm configs/foo.json`
    # propagates through the auto-reload path. Records a refresh timestamp.
    # Caller is responsible for firing on_update.
    def apply_datadir_envelope(envelope)
      # One atomic swap, like a network install (qfg-i86q).
      @store.replace_all(envelope.configs.to_h { |cfg| [cfg['key'], cfg] })
      # qfg-pinh: evaluate against the installed envelope's meta.environment,
      # matching sdk-go. In datadir mode the loader stamps meta.environment =
      # the resolved env (the `environment:` pin or QUONFIG_ENVIRONMENT), so
      # this also covers the env-var-only case where @options.environment is
      # nil at evaluator construction.
      meta = envelope.respond_to?(:meta) ? envelope.meta : nil
      env_id = meta && (meta['environment'] || meta[:environment])
      @evaluator.env_id = env_id if env_id && !env_id.to_s.empty?
      record_refresh!
    end

    # qfg-mol-2da: start the filesystem watcher for datadir auto-reload.
    # On listen-registration failure (read-only fs, missing native backend),
    # log and continue without watching — the SDK keeps serving the envelope
    # captured at init.
    def start_datadir_watcher
      return unless @options.datadir

      watcher = Quonfig::DatadirWatcher.new(
        datadir: @options.datadir,
        debounce_ms: @options.data_dir_auto_reload_debounce_ms,
        on_change: -> { reload_datadir! },
        on_error: ->(err) { LOG.warn "[quonfig] datadir watcher error: #{err.class}: #{err.message}" }
      )
      unless watcher.start
        LOG.warn '[quonfig] data_dir_auto_reload requested but watcher registration failed; continuing without auto-reload'
        return
      end
      @datadir_watcher = watcher
    end

    # Re-read the datadir into a fresh envelope and atomically install it.
    # Parse errors (mid-write JSON, garbage file) are logged and swallowed:
    # the previous envelope stays in the store and on_update does NOT fire.
    # qfg-mol-2da.
    def reload_datadir!
      return if @stopped
      return unless @options.datadir

      begin
        envelope = Quonfig::Datadir.load_envelope(@options.datadir, @options.environment)
      rescue StandardError => e
        LOG.warn "[quonfig] datadir reload failed; keeping previous envelope: #{e.class}: #{e.message}"
        return
      end

      apply_datadir_envelope(envelope)
      notify_on_update_callback
    end

    # Initialize network mode: sync HTTP fetch (bounded by
    # init_timeout_ms) then start SSE + polling as requested.
    def initialize_network_mode
      raise Quonfig::Errors::InvalidSdkKeyError, @options.sdk_key if @options.sdk_key.nil? || @options.sdk_key.to_s.strip.empty?

      warn_if_pin_ignored_in_delivery_mode
      warn_if_hedge_abort_exceeds_init_timeout
      warn_if_explicit_api_urls_disables_failover

      @network_mode = true
      # ||=: after a fork the child already built its loader over its fresh
      # store (see #reset_store_in_child!).
      @config_loader ||= Quonfig::ConfigLoader.new(@store, @options, failover_aggregator: @failover_aggregator)

      perform_initial_fetch
      start_update_channel
    end

    # SSE if enabled and it comes up; otherwise the HTTP polling fallback.
    # Polling is a fallback: if SSE is off or failed to start, poll. This
    # avoids double-work when SSE is healthy but still refreshes the store in
    # environments that block SSE (corporate proxies, Lambda, etc.).
    def start_update_channel
      # A `stop` that raced the post-fork rebuild must win: never dial a
      # stream for a client the customer has already killed (qfg-lv4n.1).
      return if @stopped
      # Idempotent. `rebuild_in_child!` disarms @fork_rebuild_pending only
      # AFTER initialize_network_mode has already started the channel, so a
      # non-StandardError landing in that window (rack-timeout,
      # Timeout::ExitException, Thread#kill) leaves the flag armed WITH a
      # live stream. The retry re-runs initialize_network_mode; without this
      # guard it dialled a SECOND stream and overwrote @sse_client, orphaning
      # the first worker where `stop` could never reach it (qfg-lv4n.1 E2).
      return if sse_worker_alive? || @poll_supervisor&.alive?

      sse_started = @options.enable_sse && start_sse
      start_polling if @options.enable_polling && !sse_started
    end

    # The init call's fetch loop (qfg-9p4i.10; init-failure design B.3 and the
    # section C log contract). Attempts the hedged primary+secondary fetch, and
    # between failed attempts sleeps a jittered 0.5s, 1s, 2s ... (30s cap) until
    # one installs. At init_timeout_ms, on_init_failure decides:
    #
    # - :fail     raise InitializationError (reason :unavailable), or
    #             InitializationTimeoutError when an attempt was still in flight
    # - :wait     keep going with no upper bound
    # - :continue return over the empty store; the update channel started by
    #             the caller keeps retrying and heals it
    #
    # Every leg answering an auth-class status (401/403/404/410) short-circuits
    # :fail and :continue at once; :wait logs it and keeps retrying (the key
    # may be provisioned late).
    #
    # init_timeout_ms <= 0 runs exactly one attempt, lets it finish (bounded by
    # the per-leg fetch timeouts, not the init deadline), then applies
    # on_init_failure. :wait keeps retrying after it (decision 8, qfg-9p4i.17).
    def perform_initial_fetch
      mode = @options.on_init_failure
      timeout_ms = @options.init_timeout_ms || Quonfig::Options::DEFAULT_INIT_TIMEOUT_MS
      timeout_ms = 0 if timeout_ms.negative?
      one_shot = timeout_ms.zero?
      timeout_s = timeout_ms / 1000.0
      start = monotonic_now
      @init_started_at = start
      deadline = start + timeout_s
      urls = Array(@options.config_api_urls)
      LOG.debug "[quonfig] init: fetching config (initTimeout=#{format_secs(timeout_s)}, onInitFailure=#{mode})",
                event: 'quonfig.init.start'

      waiting = mode == Quonfig::Options::ON_INITIALIZATION_FAILURE::WAIT
      attempt = 0
      errs = ''
      next_progress = start + init_progress_every_s
      timed_out_logged = false

      # The section C progress lines, on their own cadence: called after every
      # attempt and at each wake-up inside the backoff sleep.
      report = lambda do |now|
        if waiting && !timed_out_logged && now >= deadline
          timed_out_logged = true
          next_progress = now + INIT_WAIT_PROGRESS_EVERY_S
          LOG.warn "[quonfig] init: no config after #{format('%.1f', now - start)}s. onInitFailure=wait: still " \
                   "blocking startup and retrying indefinitely. #{errs}. Use onInitFailure=fail or continue to bound startup.",
                   event: 'quonfig.init.wait'
        end
        next unless now >= next_progress
        next unless now < deadline || waiting

        if now < deadline
          LOG.warn "[quonfig] init: still waiting for config (#{format('%.1f', now - start)}s elapsed of " \
                   "#{format_secs(timeout_s)}, attempt #{attempt}). #{errs}", event: 'quonfig.init.waiting'
          next_progress += init_progress_every_s while next_progress <= now
        else
          LOG.warn "[quonfig] init: still blocked waiting for config (#{(now - start).round}s elapsed, " \
                   "attempt #{attempt}). #{errs}", event: 'quonfig.init.waiting'
          next_progress += INIT_WAIT_PROGRESS_EVERY_S while next_progress <= now
        end
      end

      loop do
        return if @stopped

        attempt += 1
        cycle = nil
        cycle_log = @config_loader.new_cycle_log
        leg_errors = Concurrent::Map.new
        begin
          if waiting || one_shot
            cycle = @config_loader.fetch_cycle!(cycle_log: cycle_log, leg_errors: leg_errors)
          else
            # Never 0: Timeout.timeout(0) means "no timeout".
            budget = [deadline - monotonic_now, 0.001].max
            Timeout.timeout(budget) { cycle = @config_loader.fetch_cycle!(cycle_log: cycle_log, leg_errors: leg_errors) }
          end
        rescue Timeout::Error
          # An attempt was still in flight at init_timeout_ms. Its legs run on
          # until the hedge abort; their late lines go to DEBUG. Keep the leg
          # errors already known: a leg that failed fast means the attempt did
          # not hang, so the reason is :unavailable (decision 7).
          cycle_log.silence!
          errs = format_leg_errors(urls, leg_errors, in_flight: true)
          return init_timed_out(mode, timeout_s, errs, hung: attempt_hung?(urls, leg_errors))
        end

        if cycle.result != :failed
          log_init_recovered(start, attempt) if attempt > 1
          sync_evaluator_env_id!
          record_refresh!
          return
        end

        errs = format_leg_errors(urls, cycle.leg_errors)
        last_hung = attempt_hung?(urls, cycle.leg_errors)
        now = monotonic_now
        if cycle.all_legs_unauthorized?(urls.length)
          # Every leg is auth-class here (decision 6); report the primary's.
          status = cycle.primary_status
          legs = leg_names_phrase(urls.length)
          if waiting
            LOG.error "[quonfig] init: SDK key rejected (#{status}) by #{legs}. Check the key and " \
                      "environment. onInitFailure=wait: still retrying. #{errs}", event: 'quonfig.init.unauthorized'
          else
            msg = "[quonfig] init FAILED: SDK key rejected (#{status}) by #{legs}. Check the key " \
                  "and environment. onInitFailure=#{mode}: " \
                  "#{mode == Quonfig::Options::ON_INITIALIZATION_FAILURE::FAIL ? 'raising now' : 'starting on code defaults now'}."
            LOG.error msg, event: 'quonfig.init.unauthorized'
            return init_continue_on_defaults(errs) if mode == Quonfig::Options::ON_INITIALIZATION_FAILURE::CONTINUE

            raise Quonfig::Errors::InitializationError.new(
              "Quonfig init failed: SDK key rejected (#{status}) by #{legs}. #{errs}",
              reason: :unauthorized, errors: errs
            )
          end
        elsif attempt == 1 && !one_shot
          LOG.warn "[quonfig] init: config not loaded yet, retrying until initTimeout (#{format_secs(timeout_s)}). #{errs}",
                   event: 'quonfig.init.retrying'
        end

        if !waiting && now >= deadline
          # A one-shot attempt reports how long it actually took.
          elapsed_s = one_shot ? now - start : timeout_s
          return init_timed_out(mode, elapsed_s, errs, hung: last_hung)
        end

        report.call(now)

        # Decision 10 (sdk-go's rule): a new attempt starts whenever time
        # remains before the deadline, however little. If the deadline cuts it
        # off, it is the last attempt and decides the reason (the rescue
        # above); if the deadline lands in this backoff, this attempt decides.
        wake = now + init_backoff_s(attempt)
        wake = deadline if !waiting && wake > deadline
        wake_points = -> { [next_progress, (deadline if waiting && !timed_out_logged)].compact }
        init_sleep_until(wake, wake_points) { |t| report.call(t) }
        return init_timed_out(mode, timeout_s, errs, hung: last_hung) if !waiting && monotonic_now >= deadline
      end
    end

    # Sleep until +wake+, waking early at each of +wake_points+ (re-read every
    # time) to yield the current time, so progress lines keep their cadence
    # through a long backoff. Returns early once the client is stopped.
    def init_sleep_until(wake, wake_points)
      loop do
        return if @stopped

        now = monotonic_now
        return if now >= wake

        nxt = (wake_points.call.select { |t| t > now } << wake).min
        sleep(nxt - now)
        yield monotonic_now
      end
    end

    # Seconds between "still waiting for config" lines before the timeout.
    def init_progress_every_s
      INIT_PROGRESS_EVERY_S
    end

    # "primary", "primary and secondary", "primary, secondary and url2".
    def leg_names_phrase(count)
      names = Array.new([count, 1].max) { |i| leg_label(i) }
      names.length == 1 ? names.first : "#{names[0..-2].join(', ')} and #{names.last}"
    end

    def leg_label(index)
      case index
      when 0 then 'primary'
      when 1 then 'secondary'
      else "url#{index}"
      end
    end

    # 0.5s, 1s, 2s, 4s ... capped at 30s, jittered +/-20%.
    def init_backoff_s(attempt)
      base = [0.5 * (2**(attempt - 1)), INIT_BACKOFF_CAP_S].min
      base * (0.8 + (rand * 0.4))
    end

    def init_timed_out(mode, timeout_s, errs, hung:)
      elapsed = format('%.1f', timeout_s)
      if mode == Quonfig::Options::ON_INITIALIZATION_FAILURE::CONTINUE
        LOG.error "[quonfig] init: no config after #{elapsed}s. onInitFailure=continue: STARTING ON CODE DEFAULTS. " \
                  'This instance may disagree with the rest of your fleet. Retrying in background.',
                  event: 'quonfig.init.continue'
        return init_continue_on_defaults(errs)
      end

      LOG.error "[quonfig] init FAILED: no config after #{elapsed}s. #{errs}. onInitFailure=fail: raising " \
                'Quonfig::Errors::InitializationError. Options: on_init_failure: :wait to keep waiting, ' \
                'on_init_failure: :continue to start on code defaults, or raise init_timeout_ms.',
                event: 'quonfig.init.failed'
      message = "Quonfig init failed: no config after #{elapsed}s. #{errs}"
      raise Quonfig::Errors::InitializationTimeoutError.new(timeout_s, nil, message: message, errors: errs) if hung

      raise Quonfig::Errors::InitializationError.new(message, reason: :unavailable, errors: errs)
    end

    # :continue over an empty store. The update channel the caller starts next
    # keeps retrying; #record_refresh! logs the heal, and the not-ready reporter
    # logs the outage on the section C cadence until then.
    def init_continue_on_defaults(errs)
      @state_mutex.synchronize do
        @init_heal_pending = true
        @init_last_errs = errs
      end
      start_not_ready_reporter
      nil
    end

    # WARN every 30s for 5 minutes, then every 5 minutes, while a :continue
    # client has no config (section C, "Background retry while not ready").
    def start_not_ready_reporter
      return if @not_ready_reporter&.alive?

      @not_ready_reporter = Thread.new do
        Thread.current.name = 'quonfig-not-ready-reporter' if Thread.current.respond_to?(:name=)
        loop do
          elapsed = monotonic_now - @init_started_at
          sleep(elapsed < 300 ? 30 : 300)
          break if @stopped || ready?

          since = (monotonic_now - @init_started_at).round
          errs = @state_mutex.synchronize { @init_last_errs }
          LOG.warn "[quonfig] still not connected to Quonfig delivery (#{since / 60}m#{since % 60}s since start); " \
                   "serving defaults. #{errs}", event: 'quonfig.init.not_connected'
        end
      rescue StandardError
        nil
      end
    end

    def log_init_recovered(start, _attempt = nil)
      via = @config_loader.respond_to?(:resolved_from) ? @config_loader.resolved_from : ''
      # A stream install leaves resolved_from empty: name the SSE leg.
      via = sse_failed_over_to_secondary? ? leg_label(1) : leg_label(0) if via.to_s.empty?
      version = @config_loader.respond_to?(:version) ? @config_loader.version : nil
      LOG.warn "[quonfig] init recovered: config loaded after #{format('%.1f', monotonic_now - start)}s via #{via}" \
               "#{" (version #{version})" if version}. Now serving live config.", event: 'quonfig.init.recovered'
    end

    # Whether an attempt hung (decision 7): no leg failed fast. Every leg that
    # settled ended on a timeout, and a leg with no error yet was still in
    # flight when the init deadline cut the attempt off.
    def attempt_hung?(urls, leg_errors)
      urls.each_index.all? do |i|
        err = leg_errors[i]
        err.nil? || err == Quonfig::ConfigLoader::LEG_TIMED_OUT
      end
    end

    # primary=<host>: <error>; secondary=<host>: <error>. Hosts only, never the
    # SDK key or URL credentials.
    def format_leg_errors(urls, leg_errors, in_flight: false)
      urls.each_with_index.map do |url, i|
        label = leg_label(i)
        err = leg_errors[i] || (in_flight ? 'no response before initTimeout' : 'no response')
        "#{label}=#{safe_host(url)}: #{err}"
      end.join('; ')
    end

    def safe_host(url)
      uri = URI.parse(url.to_s)
      uri.host ? "#{uri.host}:#{uri.port}" : '?'
    rescue URI::InvalidURIError
      '?'
    end

    # "10s" for whole seconds, "0.5s" otherwise.
    def format_secs(secs)
      secs == secs.to_i ? "#{secs.to_i}s" : "#{secs}s"
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # qfg-pinh: In SDK-key DELIVERY mode the server's `meta.environment` is
    # AUTHORITATIVE. The server scopes each config to a single environment and
    # reports the active env id in `meta.environment` (the loader captures it
    # as @config_loader.environment_id). The evaluator must always evaluate
    # against that installed env id — matching sdk-go, where eval never
    # branches on the pin (c.envID = envelope.Meta.Environment, quonfig.go:850).
    #
    # An explicit environment pin (`environment:` option / QUONFIG_ENVIRONMENT)
    # is DATADIR-ONLY: in delivery mode it is IGNORED (it only feeds the datadir
    # loader, which stamps meta.environment = pin). So we always adopt the
    # server's env id here regardless of the pin. A WARN is emitted once at init
    # (see #warn_if_pin_ignored_in_delivery_mode) when a pin is set in delivery
    # mode so customers aren't surprised that it has no effect.
    #
    # qfg-xpln.2 originally only adopted the server env when NO pin was set,
    # which let the pin win in delivery mode — qfg-pinh reverses that.
    def sync_evaluator_env_id!
      return unless @config_loader.respond_to?(:environment_id)

      server_env = @config_loader.environment_id
      @evaluator.env_id = server_env if server_env && !server_env.to_s.empty?
    end

    # qfg-pinh: an explicit environment pin (`environment:` option or
    # QUONFIG_ENVIRONMENT) is DATADIR-ONLY. In delivery (SDK-key) mode the
    # active environment is determined by the SDK key and reported via
    # `meta.environment`, so the pin is ignored. Warn once at init so the
    # customer isn't surprised the setting has no effect. Fired only on the
    # delivery-mode init path (datadir mode honors the pin and never calls
    # this).
    def warn_if_pin_ignored_in_delivery_mode
      env = @options.environment
      return if env.nil? || env.to_s.empty?

      LOG.warn(
        "[quonfig] environment '#{env}' was set but the client is in delivery " \
        '(SDK-key) mode; the active environment is determined by the SDK key, ' \
        'so this setting is ignored (it applies only when loading from a local data dir)'
      )
    end

    DEPRECATED_INIT_FAILURE_WARNED = Set.new
    DEPRECATED_INIT_FAILURE_MUTEX = Mutex.new
    private_constant :DEPRECATED_INIT_FAILURE_WARNED, :DEPRECATED_INIT_FAILURE_MUTEX

    # One WARN per process per deprecated spelling (section C), and a WARN for
    # an unrecognized value, which runs as :fail.
    def warn_on_init_failure_spelling(options)
      if (bad = options.on_init_failure_unknown)
        LOG.warn "[quonfig] unknown on_init_failure #{bad.inspect}; using :fail (expected :fail, :wait or :continue)"
      end
      old = options.on_init_failure_alias
      return if old.nil?

      first = DEPRECATED_INIT_FAILURE_MUTEX.synchronize { DEPRECATED_INIT_FAILURE_WARNED.add?(old) }
      return unless first

      LOG.warn "[quonfig] on_init_failure=:#{old} is deprecated; use :#{options.on_init_failure}",
               event: 'quonfig.init.deprecated_alias'
    end

    # qfg-7h5d.1.14: the per-leg hedge abort MUST be < init_timeout_ms, otherwise
    # the init-path heal leg is clipped by the overall init deadline before it can
    # heal forward. Mirrors sdk-go's construction-time warning in options.go. Warn
    # once at init in delivery mode; does not change behavior.
    def warn_if_hedge_abort_exceeds_init_timeout
      return unless @options.respond_to?(:config_fetch_hedge_abort_ms)
      # The hedge (and its heal leg) only engages with a secondary leg; with a
      # single config_api_url there is no heal leg to clip, so the warning would
      # be misleading.
      return unless Array(@options.config_api_urls).length >= 2

      abort_ms = @options.config_fetch_hedge_abort_ms
      init_ms = @options.init_timeout_ms
      return if abort_ms.nil? || init_ms.nil?
      # <= 0 runs one attempt to completion; no init deadline clips its legs.
      return if init_ms <= 0
      return if init_ms > abort_ms

      LOG.warn(
        "[quonfig] init_timeout_ms (#{init_ms}ms) <= config_fetch_hedge_abort_ms " \
        "(#{abort_ms}ms); the hedged config-fetch heal leg may be clipped by the " \
        'init deadline before it can heal forward. Set init_timeout_ms above the ' \
        'hedge abort.'
      )
    end

    # qfg-41nh.26: the SDK's default (and every QUONFIG_DOMAIN-derived) api_urls
    # list carries a primary AND a secondary leg, and the HTTP config-fetch
    # hedges/fails over between them (secondary runs on separate infra). An
    # explicit `api_urls:` replaces that list wholesale, so a single-entry
    # override silently drops the secondary and disables automatic failover.
    # Warn once at init in delivery mode so the customer isn't surprised.
    # Mirrors sdk-go's construction-time warning (quonfig.go). Does not change
    # behavior. Fired only when the caller explicitly set api_urls AND the
    # resolved list has fewer than two legs — never on the default/derived
    # two-URL list.
    def warn_if_explicit_api_urls_disables_failover
      return unless @options.respond_to?(:api_urls_explicit)
      return unless @options.api_urls_explicit
      return unless Array(@options.config_api_urls).length < 2

      LOG.warn(
        '[quonfig] explicit api_urls disables automatic failover to the ' \
        'secondary; pass both primary and secondary URLs to keep it'
      )
    end

    # Returns true if SSE started successfully, false otherwise. A false here
    # signals the caller to fall back to polling.
    def start_sse
      return false if @stopped
      return false if @options.sse_api_urls.nil? || @options.sse_api_urls.empty?

      @sse_client = Quonfig::SSEConfigClient.new(
        @options,
        @config_loader,
        nil,
        nil,
        on_error: sse_error_callback,
        # First-frame rule (qfg-goi1.10.43): connected at the connection's
        # first valid frame, keepalive included, never on the 200 headers.
        # Cancels the engage timer / disengages the poller without stamping
        # last_successful_refresh (only an install or fetch does that).
        on_connected: sse_connected_callback
      )
      # The block returns the install result (:updated / :not_modified); the
      # SSE client clears its oversized gate only on :updated (qfg-6vno.20.8).
      # The connected edge comes from on_connected at the first frame (or,
      # while the oversized gate is set, at the first installed envelope), so
      # an envelope the reject-older guard drops never reports connected here.
      @sse_client.start do |envelope, _event, _source|
        next if @stopped

        begin
          result = @config_loader.apply_envelope(envelope)
          sync_evaluator_env_id!
          handle_sse_state_change(:connected) if result == :updated
          record_refresh!
        rescue StandardError => e
          LOG.warn "[quonfig] Error applying SSE envelope: #{e.message}"
          next
        end
        notify_on_update_callback
        result
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

      poll_ms = if @options.respond_to?(:fallback_poll_interval_ms) && @options.fallback_poll_interval_ms
                  @options.fallback_poll_interval_ms
                else
                  60_000
                end
      return if poll_ms <= 0

      poll_seconds = poll_ms / 1000.0
      stopped_ref = -> { @stopped }
      # Fetch-first (qfg-41nh.6): the poller fetches IMMEDIATELY on engage and
      # then sleeps the interval — matching sdk-go's fallback_poller.go
      # engage() (immediate Fetch, then ticker). A sleep-first worker made the
      # first post-engage data arrive a full extra interval late (~180s after
      # SSE loss with the default 60s interval, vs ~120s in go).
      #
      # Auth-failure rule (qfg-goi1.10.26, R2-R4): a poll cycle with no 200/304
      # on any leg and an auth-class status on the primary enters auth-failed.
      # The same worker then probes once per T in [150s, 300s] (polling mode:
      # max(T, interval)) until a probe is accepted. The flag lives on the
      # client, so a supervisor restart of this worker keeps probing.
      worker = lambda do |notify_delivered|
        loop do
          break if stopped_ref.call

          if auth_failed?
            Quonfig::Waits.sleep(:probe, auth_probe_wait(poll_seconds))
            break if stopped_ref.call

            case run_auth_probe(notify_delivered)
            when :rejected then next
            when :handed_to_sse then break
            end
            # Accepted in polling mode: resume at the interval, no immediate
            # fetch (the probe just fetched).
            Quonfig::Waits.sleep(:poll, poll_seconds)
            next
          end

          cycle = @config_loader.fetch_cycle!(log_mode: :poll)
          if cycle.auth_rejected?
            enter_auth_failed!(cycle) unless stopped_ref.call
            next
          end

          after_poll_result(cycle.result, notify_delivered)

          break if stopped_ref.call

          Quonfig::Waits.sleep(:poll, poll_seconds)
        end
      end

      supervisor = Quonfig::WorkerSupervisor.new(
        name: 'poll', layer: '2', worker: worker
      )
      @state_mutex.synchronize { @poll_supervisor = supervisor }
      supervisor.start
      # Operator signal (qfg-41nh.6): engage was previously unlogged (only the
      # stop path logged, at debug). Matches sdk-go's WARN on OnEngage — the
      # poller engaging means the SDK is in a degraded update mode.
      LOG.warn "[quonfig] Layer 2 fallback poller engaged (interval=#{poll_ms}ms)"
    end

    # Liveness honesty (qfg-41nh.6): stamp freshness only when the fetch
    # actually SUCCEEDED. :updated and :not_modified (a 304, or a
    # guard-rejected-but-successful response) are successes — the channel is
    # healthy; :failed must NOT advance last_successful_refresh (pre-fix every
    # tick stamped + notified regardless of outcome, so ready?/freshness
    # reported healthy over an empty store through a total outage). on_update
    # fires only on a real install, matching sdk-go (OnConfigUpdate fires in
    # installEnvelope only).
    def after_poll_result(result, notify_delivered)
      if result != :failed
        sync_evaluator_env_id!
        record_refresh!
        notify_delivered.call
      end
      notify_on_update_callback if result == :updated
    end

    def auth_failed?
      @state_mutex.synchronize { @auth_failed }
    end

    # Rule R3: T uniform in [150s, 300s], re-drawn per probe, never doubled.
    # With SSE disabled the wait is max(T, poll interval). Internal: tests
    # reach it through Quonfig::Waits, it is not a customer option.
    def auth_probe_wait(poll_seconds)
      t = AUTH_PROBE_MIN_SECONDS + (rand * (AUTH_PROBE_MAX_SECONDS - AUTH_PROBE_MIN_SECONDS))
      t = poll_seconds if !@options.enable_sse && poll_seconds > t
      t
    end

    # Entry (R2-R5), on the poller's thread, in this order: SSE off (stream
    # closed and its worker joined, the engage timer cancelled), the flag up,
    # then one ERROR naming the status and the primary host, never the key.
    def enter_auth_failed!(cycle)
      cancel_fallback_engage_timer
      sse = @state_mutex.synchronize do
        @auth_failed = true
        @sse_state = :idle
        s = @sse_client
        @sse_client = nil
        s
      end
      begin
        sse&.close
      rescue StandardError => e
        LOG.debug "Error closing SSE client on auth-failed entry: #{e.message}"
      end
      LOG.error "[quonfig] config fetch rejected (HTTP #{cycle.primary_status} from #{cycle.primary_host}): " \
                'the SDK key is invalid or revoked (check the SDK key); streaming and polling stopped, ' \
                'retrying every few minutes until it is accepted'
    end

    # One auth-failed probe: a fetch cycle across every leg (R3), logged at
    # DEBUG only. The first valid 200 or a 304 on any leg exits (R4): one
    # INFO, and SSE restarts from its base backoff (a brand-new stream
    # client), handing the update channel back from this poller. With SSE
    # disabled the poller resumes polling. Returns :rejected, :handed_to_sse
    # or :resume_polling.
    def run_auth_probe(notify_delivered)
      cycle = @config_loader.fetch_cycle!(log_mode: :probe)
      if cycle.result == :failed
        LOG.debug "[quonfig] auth-failed probe rejected (HTTP #{cycle.primary_status} from #{cycle.primary_host}); " \
                  'retrying later'
        return :rejected
      end

      after_poll_result(cycle.result, notify_delivered)
      handing_to_sse = @options.enable_sse && !@stopped
      # Stop this poller first (from its own thread: WorkerSupervisor#stop only
      # flags it) so connection_state never reads falling_back on the way out.
      stop_fallback_poller('auth-recovered') if handing_to_sse
      @state_mutex.synchronize { @auth_failed = false }
      LOG.info '[quonfig] config fetch accepted; leaving auth-failed and resuming streaming and polling'
      return :resume_polling unless handing_to_sse

      start_sse
      :handed_to_sse
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
        # Counted, not a worker restart (supervisor contract Test 5).
        @state_mutex.synchronize { @callback_errors['on_config_update'] += 1 }
        bt = (e.backtrace || []).first(10).join("\n  ")
        LOG.error "[quonfig] onConfigUpdate callback raised: #{e.class}: #{e.message}\n  #{bt}"
      end
    end

    def build_context(jit_context)
      jit = jit_context == NO_DEFAULT_PROVIDED ? nil : normalize_context(jit_context)
      merge_contexts(@global_context, jit)
    end

    # Combine the customer-supplied globalContext with the optional dev
    # context loaded from ~/.quonfig/tokens.json. Dev context goes UNDER the
    # customer's, so an explicit customer `quonfig-user` context replaces it.
    def build_initial_global_context(options)
      customer = normalize_context(options.global_context)
      return customer unless dev_context_enabled?(options)

      dev = Quonfig::DevContext.load_quonfig_user_context
      return customer if dev.nil?

      merge_contexts(dev, customer)
    end

    # Tri-state resolution for dev-context injection. Default ON, gated only
    # by the presence of the tokens file (the loader no-ops without it ->
    # dead in prod). Precedence: an explicit option (non-nil) wins, else
    # QUONFIG_DEV_CONTEXT ('true'/'false'), else true.
    def dev_context_enabled?(options)
      opt = options.enable_quonfig_user_context
      return opt == true unless opt.nil?

      case ENV.fetch('QUONFIG_DEV_CONTEXT', nil)
      when 'true' then true
      when 'false' then false
      else true
      end
    end

    def normalize_context(ctx)
      return {} if ctx.nil?
      return ctx if ctx.is_a?(Hash)

      raise ArgumentError, "Quonfig context must be a Hash, got #{ctx.class}"
    end

    # Combine two context tiers (qfg-2agi.24): a named context in +right+
    # REPLACES the whole same-named context in +left+ (no per-property merge);
    # named contexts only in +left+ survive. Names compare as strings, so
    # +:user+ and +'user'+ are the same named context.
    def merge_contexts(left, right)
      return right || {} if left.nil? || left.empty?
      return left if right.nil? || right.empty?

      merged = {}
      left.each { |name, ctx| merged[name] = ctx.is_a?(Hash) ? ctx.dup : ctx }
      right.each do |name, ctx|
        merged.delete_if { |existing, _| existing.to_s == name.to_s }
        merged[name] = ctx.is_a?(Hash) ? ctx.dup : ctx
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

    # A delivery-mode client that has never installed config (init continued
    # on code defaults, or the caller caught a failed init): the *_details
    # getters answer ERROR / PROVIDER_NOT_READY (init-failure design B.3)
    # rather than claiming the key does not exist.
    def provider_not_ready?
      @network_mode && !ready?
    end

    def provider_not_ready_details
      Quonfig::EvaluationDetails.new(
        value: nil,
        reason: Quonfig::EvaluationDetails::REASON_ERROR,
        error_code: Quonfig::EvaluationDetails::ERROR_PROVIDER_NOT_READY,
        error_message: 'Quonfig has not loaded config yet',
        variant: build_variant(Quonfig::EvaluationDetails::REASON_ERROR, nil, nil),
        flag_metadata: build_flag_metadata(nil, nil, nil, nil, nil)
      )
    end

    # Build a Quonfig::EvaluationDetails for +key+, evaluated against the
    # caller's context, after coercing/checking +expected_type+. Never
    # raises; all exceptions become ERROR details.
    def evaluate_details(key, expected_type, context)
      ensure_initialized_after_fork
      jit = context == NO_DEFAULT_PROVIDED ? nil : context
      ctx = build_context(jit)
      record_context_for_telemetry(ctx)
      return provider_not_ready_details if provider_not_ready?

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
        rescue Quonfig::Errors::EnvVarParseError => e
          # An ENV_VAR value that does not parse as the config's type is
          # TYPE_MISMATCH, like a malformed stored value (as in sdk-go).
          return Quonfig::EvaluationDetails.new(
            value: nil,
            reason: Quonfig::EvaluationDetails::REASON_ERROR,
            error_code: Quonfig::EvaluationDetails::ERROR_TYPE_MISMATCH,
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

      begin
        coerced = typed_value(key, result, expected_type)
      rescue Quonfig::Errors::TypeMismatchError, Quonfig::Errors::EnvVarParseError => e
        # A wrong-type value and a malformed one (the getter cannot produce
        # a value of its type) are both TYPE_MISMATCH, as in sdk-go.
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
      flag_metadata = build_flag_metadata(
        config_id, config_type, result.rule_index, result.weighted_value_index, reason
      )
      flag_metadata['hashPropertyMissing'] = true if result.hash_property_missing
      Quonfig::EvaluationDetails.new(
        value: coerced,
        reason: reason,
        variant: build_variant(reason, result.rule_index, result.weighted_value_index),
        flag_metadata: flag_metadata
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

    # A typed read under the typed-getter contract (qfg-zvyy, shared with
    # every Quonfig SDK and pinned by integration-test-data getter.contract.*).
    #
    # A missing key returns +default+ or applies +on_no_default+. A read that
    # fails (a value of another type, a malformed stored or ENV_VAR value, an
    # unset ENV_VAR, a decryption failure) returns +default+ when one is
    # given; with no default it returns nil under on_no_default: :return_nil
    # and raises the error (TypeMismatchError, EnvVarParseError,
    # MissingEnvVarError, DecryptionError) under :raise. Either way it logs
    # one WARN per key per client.
    def typed_get(key, expected_type, default:, context:)
      ensure_initialized_after_fork
      ctx = build_context(context)
      record_context_for_telemetry(ctx)
      begin
        result = resolve_for_read(key, ctx)
        return handle_missing(key, default) if result.nil?

        record_evaluation_for_telemetry(result)
        typed_value(key, result, expected_type)
      rescue *READ_FAILURES => e
        failed_read(key, default, e)
      end
    end

    # The resolved Evaluation for +key+, or nil when the key is missing or no
    # rule matched. Resolution errors (MissingEnvVarError, EnvVarParseError,
    # DecryptionError) propagate.
    def resolve_for_read(key, ctx)
      @resolver.get(key, ctx)
    rescue Quonfig::Errors::MissingDefaultError
      nil
    end

    # +result+'s value with no type check. A stored value that does not parse
    # as its declared type (an int "twelve", a duration "30s") raises
    # EnvVarParseError, as a malformed ENV_VAR value does.
    def unwrap_for_read(result)
      value =
        begin
          result.unwrapped_value
        rescue ArgumentError, TypeError, FloatDomainError
          raise malformed_stored_value_error(result)
        end
      raise malformed_stored_value_error(result) if malformed_stored_duration?(result, value)

      value
    end

    # +result+'s value as +expected_type+, or raise TypeMismatchError (a value
    # of another type) / EnvVarParseError (a malformed value). Strings are
    # never coerced: a stored "false" is not a bool and "3" is not an int.
    def typed_value(key, result, expected_type)
      stored = stored_value_type(result)
      accepted = ACCEPTED_TYPES.fetch(expected_type)
      raise Quonfig::Errors::TypeMismatchError.new(key, TYPE_NAMES.fetch(expected_type), nil, actual_type: stored) unless stored.nil? || accepted.include?(stored)

      value = unwrap_for_read(result)
      return nil if value.nil?

      if [Integer, Float].include?(expected_type)
        typed_number(key, result, value, expected_type)
      elsif expected_type == :bool
        typed_bool(key, result)
      else
        check_class(key, value, expected_type)
      end
    end

    # The Value's declared type ('int', 'string', ...); a resolved ENV_VAR or
    # decrypted value carries the type it was coerced to. Nil when unknown.
    def stored_value_type(result)
      type = result.type
      if type.nil? || type == 'provided'
        config = result.config || {}
        type = config['valueType'] || config[:valueType] || config['value_type'] || config[:value_type]
      end
      type&.to_s
    end

    # Double getter: any int or double (30 -> 30.0). Int getter: an int, or a
    # double that is whole and within +/-(2^53-1) (3.0 -> 3). Never truncates:
    # 3.9, 1e300 and NaN are type mismatches.
    def typed_number(key, result, value, expected_type)
      # A stored int whose raw value is a Float would unwrap truncated.
      raw = result.raw_value
      number = raw.is_a?(Numeric) ? raw : value
      mismatch = -> { Quonfig::Errors::TypeMismatchError.new(key, TYPE_NAMES.fetch(expected_type), number) }
      raise mismatch.call unless number.is_a?(Integer) || number.is_a?(Float)

      return number.to_f if expected_type == Float
      return number if number.is_a?(Integer)
      raise mismatch.call unless number.finite? && number == number.floor && number.abs <= MAX_SAFE_INTEGER

      number.to_i
    end

    # A bool Value unwraps with !!raw, so check the raw value: only a real
    # true/false is a bool.
    def typed_bool(key, result)
      raw = result.raw_value
      raise Quonfig::Errors::TypeMismatchError.new(key, 'Boolean', raw) unless [true, false].include?(raw)

      raw
    end

    def check_class(key, value, expected_type)
      ok =
        if expected_type == String then value.is_a?(String)
        elsif expected_type == :string_list then value.is_a?(Array) && value.all?(String)
        elsif expected_type == :duration then value.is_a?(Integer)
        else true # :json: any JSON value
        end
      raise Quonfig::Errors::TypeMismatchError.new(key, TYPE_NAMES.fetch(expected_type), value) unless ok

      value
    end

    # A stored duration string outside the shared grammar unwraps to nil.
    def malformed_stored_duration?(result, unwrapped)
      unwrapped.nil? && result.type == 'duration' && !result.raw_value.nil?
    end

    def malformed_stored_value_error(result)
      Quonfig::Errors::EnvVarParseError.new(result.raw_value, result.config || {}, nil, stored: true)
    end

    # The failed-read rule (qfg-zvyy): +default+ when one is given, else nil
    # under on_no_default: :return_nil, each with one WARN per key; else
    # +error+ under :raise (the raise is the signal, so it is not logged).
    def failed_read(key, default, error)
      no_default = default == NO_DEFAULT_PROVIDED
      raise error if no_default && @options.on_no_default == Quonfig::Options::ON_NO_DEFAULT::RAISE

      warn_read_failure(key, "#{error.message}; #{no_default ? 'returning nil' : 'returning the default'}")
      no_default ? nil : default
    end

    # Logs once per config key per client. The reason names the key and the
    # types involved, never the value (it can be a decrypted secret).
    def warn_read_failure(key, reason)
      return unless @read_failure_mutex.synchronize { @read_failure_warned.add?(key.to_s) }

      LOG.warn "[quonfig] read of #{key.to_s.inspect} returned no value: #{reason}"
    end
  end

  # qfg-ryov / qfg-lv4n.1: hook into Process._fork so customers using Puma's
  # clustered mode (or any preload/fork-worker server, or a gem that forks
  # inside a job) don't have to wire +before_fork+/+on_worker_boot+ manually.
  # Ruby 3.1+ routes every +Kernel#fork+/+Process.fork+ call through
  # +Process._fork+, so a single prepend covers them all.
  #
  # Process._fork's contract:
  #   - Called in the parent process before the fork syscall.
  #   - Returns 0 in the child, child's pid in the parent.
  #   - +super+ performs the actual fork.
  #
  # **The hook is child-only.** Nothing happens in the parent — not before
  # the syscall, not after it. A fork is somebody else's business; the
  # process that forked keeps its SSE stream, its poller, its telemetry
  # reporter, and its live config. This is Reforge's model (+Reforge.fork+
  # builds a new client in the child and never touches the old one) and
  # matches dd-trace-rb, redis-client and connection_pool, which all branch
  # on the child stage of +_fork+ only.
  #
  # It replaces the qfg-ryov shape, which tore the parent down before the
  # syscall on the theory that the child must not inherit a live socket fd.
  # That was wrong twice over: the child never touches the inherited fd (it
  # drops the reference — see Client#after_fork_in_child), and a Sidekiq
  # parent that forks a worker and keeps evaluating went dark for 13 days in
  # production.
  module ForkSafety
    def _fork
      pid = super
      if pid.zero?
        # Per-instance, not per-fan-out: a process can hold more than one
        # Client (a second workspace, a test harness, a gem that builds its
        # own). One of them failing to rebuild — thread exhaustion, a
        # customer logger that raises — must not cost every client behind it
        # in the registry its rebuild and leave the child silently dark.
        Quonfig::Client.each_instance do |client|
          client.after_fork_in_child
        rescue StandardError => e
          Quonfig::Client::LOG.error 'Quonfig fork rebuild failed for one client ' \
                                     "(continuing with the rest): #{e.class}: #{e.message}"
        end
      end
      pid
    rescue StandardError => e
      # Fork-hook failures must never break the customer's fork. Worst case
      # the child holds dropped references and no live threads — bad, but
      # recoverable. Crashing the fork itself is not.
      Quonfig::Client::LOG.error "Quonfig fork hook error: #{e.class}: #{e.message}"
      raise if pid.nil? # super never returned — propagate fork failures

      pid
    end
  end

  # Ruby 3.0 lacks Process._fork. There's no hookable choke point on 3.0, so
  # customers must keep wiring their own Puma before_fork / on_worker_boot
  # (see README "Rails integration"). On 3.1+ we install the hook globally.
  Process.singleton_class.prepend(ForkSafety) if Process.respond_to?(:_fork)
end
