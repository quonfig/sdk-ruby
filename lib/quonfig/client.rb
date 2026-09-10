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
      @sse_terminal_failure = false
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
      self.class.register_instance(self) unless store
    end

    # ---- Lookup --------------------------------------------------------

    def get(key, default = NO_DEFAULT_PROVIDED, jit_context = NO_DEFAULT_PROVIDED)
      ensure_initialized_after_fork
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
    # The hook does NO I/O: no fetch, no socket, no thread. It throws away
    # everything the child inherited — including the parent's config snapshot
    # — and arms a flag. The child re-initializes on its FIRST use of the
    # client (see #ensure_initialized_after_fork), exactly like a newly
    # constructed client would. A child that never uses the client, which is
    # most of them in a `Parallel.map` batch, costs nothing at all.
    def after_fork_in_child
      return if @stopped

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
      @sse_terminal_failure = false
      @sse_error_callback = nil

      # A client that never finished network init has nothing to rebuild.
      return if @config_loader.nil? && !@options.datadir

      # A brand-new, EMPTY store. The child must not evaluate from whatever
      # snapshot the parent happened to hold at the instant of the fork: it
      # fetches (or loads) its own on first use.
      reset_store_in_child!

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

    def fork
      self.class.new(@options.for_fork)
    end

    def inspect
      "#<Quonfig::Client:#{object_id} environment=#{@options.environment.inspect}>"
    end

    private

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

      return unless @options.on_init_failure == Quonfig::Options::ON_INITIALIZATION_FAILURE::RAISE

      # Parity with a fresh Client.new, which raises under :raise. Stored so
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

    def handle_sse_error(error)
      # qfg-i5xv: classify terminal HTTP failures (401/403/404). The same SDK
      # key that won't auth over SSE won't auth over HTTP polling either, so
      # we must NOT engage the Layer 2 fallback — that just moves the
      # auth-failure storm from one endpoint to another. Once flipped,
      # @sse_terminal_failure latches: a buggy customer retry loop cannot
      # un-classify the failure by driving the state machine.
      @state_mutex.synchronize { @sse_terminal_failure = true } if error.is_a?(Quonfig::SSEConfigClient::SSEHTTPTerminalError)
      handle_sse_state_change(:error)
    end

    def handle_sse_state_change(new_state)
      state = new_state.to_sym
      ever_connected, terminal = @state_mutex.synchronize do
        @sse_state = state
        @sse_ever_connected = true if state == :connected
        [@sse_ever_connected, @sse_terminal_failure]
      end

      return unless @options.respond_to?(:fallback_poll_enabled) && @options.fallback_poll_enabled
      return if @stopped
      # qfg-i5xv: a terminal SSE classification suppresses polling engage in
      # every branch — the customer's key is bad and HTTP polling will fail
      # identically. Operators surface this via #terminal_failure?.
      return if terminal

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

    # qfg-i5xv: true once the SSE layer has classified an HTTP response as
    # terminal (401/403/404) — bad SDK key, revoked workspace permission,
    # or wrong endpoint. The classification latches: the SDK will not
    # auto-recover, and a customer-supplied retry must rebuild the client.
    # Surfaced for operator alerting; `connection_state` still reports
    # `:disconnected` to honor the documented connection_state vocabulary
    # (supervisor-test-contract.md §"connectionState()" — values fixed).
    def terminal_failure?
      @state_mutex.synchronize { @sse_terminal_failure }
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
          sleep grace_seconds
          @state_mutex.synchronize { @fallback_engage_timer = nil }
          start_polling unless @stopped
        end
      end
    end

    # Construct and start the telemetry reporter if the options permit it.
    # The reporter runs on a background thread and periodically POSTs
    # context-shape and example-context batches to +telemetry_destination+.
    def initialize_telemetry(start: true)
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
        failover_aggregator: @failover_aggregator,
        sync_interval: @options.collect_sync_interval
      )

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
      apply_datadir_envelope(envelope)
    end

    # Apply a freshly loaded datadir envelope to the store. Keys that were
    # present before but missing now are deleted, so a `rm configs/foo.json`
    # propagates through the auto-reload path. Records a refresh timestamp.
    # Caller is responsible for firing on_update.
    def apply_datadir_envelope(envelope)
      new_keys = envelope.configs.map { |cfg| cfg['key'] }.compact.to_set
      old_keys = @store.keys.to_set
      (old_keys - new_keys).each { |k| @store.delete(k) }
      envelope.configs.each { |cfg| @store.set(cfg['key'], cfg) }
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

      sse_started = @options.enable_sse && start_sse
      start_polling if @options.enable_polling && !sse_started
    end

    def perform_initial_fetch
      timeout = (@options.init_timeout_ms || 10_000) / 1000.0
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
        sync_evaluator_env_id!
        record_refresh!
      end
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
      return false if @stopped
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
          sync_evaluator_env_id!
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
      worker = lambda do |notify_delivered|
        loop do
          break if stopped_ref.call

          result = @config_loader.fetch!
          # Liveness honesty (qfg-41nh.6): stamp freshness only when the fetch
          # actually SUCCEEDED. :updated and :not_modified (a 304, or a
          # guard-rejected-but-successful response) are successes — the
          # channel is healthy; :failed must NOT advance
          # last_successful_refresh (pre-fix every tick stamped + notified
          # regardless of outcome, so ready?/freshness reported healthy over
          # an empty store through a total outage). on_update fires only on a
          # real install, matching sdk-go (OnConfigUpdate fires in
          # installEnvelope only).
          if result != :failed
            sync_evaluator_env_id!
            record_refresh!
            notify_delivered.call
          end
          notify_on_update_callback if result == :updated

          break if stopped_ref.call

          sleep poll_seconds
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
      ensure_initialized_after_fork
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
