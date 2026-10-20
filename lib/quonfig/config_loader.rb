# frozen_string_literal: true

require 'json'
require 'uri'

module Quonfig
  # Fetches config envelopes from the Quonfig delivery API and installs them
  # into a ConfigStore.
  #
  # Wire format matches sdk-node's Transport + ConfigStore:
  #   GET /api/v2/configs
  #     -> 200 { "configs": [...], "meta": { "version": "...", "environment": "..." } }
  #     -> 304 Not Modified (ETag honored via If-None-Match)
  #
  # The fetch is synchronous; Client is responsible for timing out the initial
  # fetch per `init_timeout_ms`.
  class ConfigLoader
    LOG = Quonfig::InternalLogger.new(self)

    CONFIGS_PATH = '/api/v2/configs'

    # Rule R1 (qfg-goi1.10.26): the auth class. A fetch cycle with no 200/304
    # on any leg and one of these on the primary leg is rejected; the client's
    # poller then enters auth-failed (Client#start_polling).
    AUTH_STATUSES = [401, 403, 404, 410].freeze

    # Result of one fetch cycle across the configured legs. +statuses+ maps a
    # config_api_urls index to the HTTP status that leg returned (0 = no
    # response: timeout, connection failure). +primary_host+ is host:port of
    # the primary leg, for the entry ERROR (never the key).
    class FetchCycle
      attr_reader :result, :statuses, :primary_host, :leg_errors

      # +leg_errors+ maps a config_api_urls index to a one-line description of
      # why that leg failed (host-free, key-free), for the init log contract.
      def initialize(result, statuses, primary_host, leg_errors = {})
        @result = result
        @statuses = statuses
        @primary_host = primary_host
        @leg_errors = leg_errors
      end

      # Every leg answered and every answer was in the auth class (401/403,
      # plus 404/410 per rule R1): the key is rejected (init-failure design
      # B.3, "401/403 from both legs"). Stricter than #auth_rejected? (the
      # poller's rule R2, primary leg only), because init short-circuits on it.
      def all_legs_unauthorized?(leg_count)
        return false unless @result == :failed

        values = @statuses.values
        values.size >= leg_count && values.all? { |s| AUTH_STATUSES.include?(s) }
      end

      def primary_status
        @statuses[0] || 0
      end

      # Rule R2: no leg returned 200/304 and the primary returned an
      # auth-class status. A 200 the guard dropped, or a 304, never qualifies.
      def auth_rejected?
        return false unless @result == :failed
        return false if @statuses.values.any? { |s| [200, 304].include?(s) }

        AUTH_STATUSES.include?(primary_status)
      end
    end

    # Collects one cycle's per-leg log lines. +mode+:
    #   :normal - log at once, as always (init fetch, refresh, legacy callers)
    #   :poll   - a poller cycle: hold the auth-class lines until the cycle is
    #             classified, so an entering cycle logs its one ERROR in their
    #             place (rule R5); otherwise they are logged unchanged
    #   :probe  - an auth-failed probe: every line at DEBUG (rule R5)
    class CycleLog
      def initialize(logger, mode)
        @logger = logger
        @mode = mode
        @held = []
        @released = false
        @mutex = Mutex.new
      end

      def log(level, msg, auth: false)
        return @logger.debug(msg) if @mode == :probe

        if @mode == :poll && auth
          hold = @mutex.synchronize do
            @held << [level, msg] unless @released
            !@released
          end
          return if hold
        end
        @logger.public_send(level, msg)
      end

      # Log (or with +drop+, discard) the held lines. Lines from a leg that
      # settles later are logged as they come.
      def release(drop: false)
        held = @mutex.synchronize do
          @released = true
          h = @held
          @held = []
          h
        end
        held.each { |level, msg| @logger.public_send(level, msg) } unless drop
      end
    end

    attr_reader :version, :environment_id

    # qfg-7h5d.1.9 (canonical ordering). Diagnostic surface read by the failover/
    # ordering chaos probe and by operators:
    #   held_generation — Meta.generation of the currently-installed envelope
    #                     (nil before the first install).
    #   install_count   — number of envelopes actually installed (rejected-older
    #                     and same-generation snapshots do NOT bump this).
    #   resolved_from   — 'primary' / 'secondary' / '' — which config_api_urls leg
    #                     produced the currently-held config (HTTP installs only;
    #                     SSE does not change it).
    attr_reader :held_generation, :install_count

    # Repoint the failover-telemetry sink. The one caller is
    # Client#after_fork_in_child: a forked child gets fresh aggregators (the
    # parent still owns and flushes its own), and the loader has to record
    # into the child's copy rather than the inherited one (qfg-lv4n.1).
    attr_writer :failover_aggregator

    # +store+: the Quonfig::ConfigStore to populate on successful fetch.
    # +options+: a Quonfig::Options instance (supplies sdk_key + config_api_urls).
    # +logger+: optional logger override (defaults to module LOG).
    #
    # Backward compat: callers that pass a single +base_client+ (mock client
    # used by tests that expects `.options`) are still supported.
    def initialize(store_or_base_client, options = nil, logger: nil, failover_aggregator: nil)
      if options.nil? && store_or_base_client.respond_to?(:options)
        # Legacy shape: ConfigLoader.new(base_client)
        @options = store_or_base_client.options
        @store = nil
      else
        @store = store_or_base_client
        @options = options
      end

      # Optional failover-telemetry sink (qfg-41nh.18). When telemetry is
      # enabled the Client passes the shared FailoverAggregator; nil otherwise,
      # so every record call below is a no-op under a telemetry opt-out.
      @failover_aggregator = failover_aggregator

      @api_config = Concurrent::Map.new
      # qfg-7h5d.1.14: per-leg ETag is load-bearing for the parallel hedge. The
      # hedge runs the primary and secondary legs concurrently; a SINGLE shared
      # ETag would (a) let a 304 from one leg mask the other and (b) be a data
      # race with two legs writing it. Each leg keeps its own slot keyed by
      # config_api_urls index, guarded by @etag_mutex (snapshot before the
      # request, write-back after — the network wait happens with no lock held).
      @etags = {}
      @etag_mutex = Mutex.new
      @version = nil
      @environment_id = nil
      @logger = logger || LOG

      # Canonical-ordering state (qfg-7h5d.1.9). @install_mutex makes the
      # guard-check-and-install atomic across every install path (initial fetch,
      # failover/poll fetch, SSE snapshot, SSE update, fallback poller) — these
      # run on different threads and must never interleave a stale install with a
      # fresh one.
      @held_generation = nil
      @install_count = 0
      @resolved_from_index = nil
      @install_mutex = Mutex.new
    end

    # Backward-compatible reader: the primary leg's last ETag. Pre-hedge this was
    # a single shared @etag; per-leg isolation now means index 0 is the canonical
    # "the ETag" for callers/tests that read one value.
    def etag
      @etag_mutex.synchronize { @etags[0] }
    end

    # 'primary' / 'secondary' / '' for the leg that produced the currently-held
    # config (config_api_urls index 0 = primary, 1 = secondary).
    def resolved_from
      case @resolved_from_index
      when nil then ''
      when 0 then 'primary'
      when 1 then 'secondary'
      else "url#{@resolved_from_index}"
      end
    end

    # Fetch configs from /api/v2/configs with per-leg ETag / If-None-Match caching.
    #
    # qfg-7h5d.1.14 — PARALLEL-FAILOVER HEDGE. On every init/refresh fetch the
    # PRIMARY leg (config_api_urls[0]) is fired first, on the CALLING thread. If
    # it answers within config_fetch_hedge_delay_ms it WINS and the secondary is
    # NEVER contacted (cold standby — zero extra load on a healthy system). If the
    # primary is SLOW past the hedge delay OR errors fast, the SECONDARY leg
    # (config_api_urls[1]) is ALSO fired IN PARALLEL on a background thread,
    # at-most-once — the primary is NOT cancelled. Whatever arrives is installed
    # through the EXISTING reject-older guard (#install_envelope), so watermark-MAX
    # falls out for free: a higher generation wins, a late OLDER payload never
    # regresses an established client, and a late NEWER payload heals forward.
    #
    # fetch! returns as soon as the FIRST leg installs (readiness latches off it);
    # any still-running leg keeps running on its own thread, bounded by
    # config_fetch_hedge_abort_ms, and heals forward if it lands a newer
    # generation. There is NO coalescing/in-flight gate — overlapping fetches are
    # safe (per-leg ETag isolation + every install serialized through
    # @install_mutex + the reject-older guard + each leg bounded by the abort), and
    # a coalescing gate would make a manual refresh silently no-op (a contract
    # violation).
    #
    # Returns one of:
    #   :updated       -- at least one leg installed a 200 envelope
    #   :not_modified  -- a leg answered 304 (no change) and nothing installed
    #   :failed        -- every fired leg failed
    def fetch!
      fetch_cycle!.result
    end

    # One fetch cycle, as #fetch!, returning a FetchCycle that carries each
    # leg's status (rule R2, qfg-goi1.10.26). +log_mode+ is one of CycleLog's
    # modes; the poller passes :poll for an ordinary cycle and :probe while
    # auth-failed.
    def fetch_cycle!(log_mode: :normal)
      urls = Array(@options.config_api_urls)
      statuses = Concurrent::Map.new
      leg_errors = Concurrent::Map.new
      return FetchCycle.new(:failed, statuses, '', leg_errors) if urls.empty?

      cycle_log = CycleLog.new(@logger, log_mode)
      # Single leg (or no secondary configured): no hedge, just fetch on the
      # calling thread under the SEQUENTIAL per-URL timeout (config_fetch_timeout_ms
      # is unchanged and still governs any non-hedged path). Preserves the
      # synchronous, single-request-per-call shape the legacy/mock callers depend
      # on.
      result = if urls.length < 2
                 fetch_from(urls[0], 0, timeout_ms: config_fetch_timeout_ms, statuses: statuses,
                                        cycle_log: cycle_log, leg_errors: leg_errors)
               else
                 fetch_hedged(urls, statuses: statuses, cycle_log: cycle_log, leg_errors: leg_errors)
               end
      cycle = FetchCycle.new(result, statuses, host_of(urls[0]), leg_errors)
      cycle_log.release(drop: cycle.auth_rejected?)
      cycle
    end

    # Apply a ConfigEnvelope (from SSE) to the store. Called by the SSE client
    # when a new event arrives. SSE is a single-leg live stream, so it carries no
    # config_api_urls index and does not change #resolved_from — but it IS
    # guarded by the same reject-older rule (a late SSE snapshot must not regress
    # an established client).
    def apply_envelope(envelope)
      install_envelope(envelope, source: :sse, source_index: nil)
    end

    def calc_config
      rtn = {}
      @api_config.each_key do |k|
        rtn[k] = @api_config[k]
      end
      rtn
    end

    def set(config, source)
      @api_config[config.key] = { source: source, config: config }
    end

    def rm(key)
      @api_config.delete(key)
    end

    private

    # Hedge orchestration (qfg-7h5d.1.14). Fires the primary leg on its own
    # thread; if it is slow past the hedge delay OR errors fast, ALSO fires the
    # secondary in parallel — at-most-once, never after a fast primary win, never
    # cancelling the primary. Both legs push their settled result to a shared
    # queue. fetch! returns as soon as the FIRST leg INSTALLS (so readiness
    # latches off it); the other leg keeps running on its own thread, bounded by
    # the hedge abort inside fetch_from, and heals forward through the
    # reject-older guard. We never join the slow leg — a hung primary must not
    # block a successful secondary install.
    def fetch_hedged(urls, statuses: nil, cycle_log: nil, leg_errors: nil)
      hedge_delay_s = hedge_delay_ms / 1000.0
      abort_ms = hedge_abort_ms

      # Each fired leg pushes exactly one [:done, index, result] message. A
      # SizedQueue large enough for both legs so a finished leg never blocks on
      # push after we've stopped draining.
      results = Queue.new

      # At-most-once secondary gate. The mutex makes "a fast primary win
      # suppresses the secondary" and "the hedge-delay elapsing fires it"
      # mutually exclusive — exactly one of suppress/fire wins.
      gate = Mutex.new
      secondary_fired = false
      # Distinct from secondary_fired (which is ALSO set true by suppress on a
      # fast primary win): this is set only when the secondary leg was ACTUALLY
      # spawned, so it is the exact "the hedge fired" signal (qfg-41nh.18).
      secondary_spawned = false

      # Each leg is wall-clock bounded by abort_ms (HttpConnection enforces a
      # whole-request deadline, qfg-41nh.6), so a leg ALWAYS settles — a
      # slow-drip upstream can no longer hold a leg open past the abort and
      # wedge the drain below. The push lives in an ensure so even a
      # non-StandardError escape still settles this leg's drain slot.
      run_leg = lambda do |index|
        Thread.new do
          result = :failed
          begin
            result = fetch_from(urls[index], index, timeout_ms: abort_ms, statuses: statuses, cycle_log: cycle_log,
                                                    leg_errors: leg_errors)
          rescue StandardError => e
            @logger.debug "Hedge leg #{index} failed: #{e.class}: #{e.message}"
          ensure
            results.push([:done, index, result])
          end
        end
      end

      fire_secondary = lambda do
        spawn = gate.synchronize do
          next false if secondary_fired

          secondary_fired = true
          secondary_spawned = true
        end
        run_leg.call(1) if spawn
      end

      suppress_secondary = lambda do
        gate.synchronize { secondary_fired = true }
      end

      # The primary always runs. A separate hedge-delay timer thread fires the
      # secondary if the primary has not settled by then — without waiting for
      # the primary to finish.
      primary_thread = run_leg.call(0)

      hedge_timer = Thread.new do
        sleep hedge_delay_s
        # If the primary is still in flight at the hedge delay, hedge in parallel.
        fire_secondary.call if primary_thread.alive?
      end

      installed = false
      saw_not_modified = false
      drained = 0

      # Drain leg results until the FIRST install latches readiness, or until
      # every fired leg has reported (so a both-fail / both-304 cycle still
      # terminates). `fired` is read under the gate because the secondary can be
      # spawned concurrently by the timer or the primary's fast-error path.
      loop do
        fired = gate.synchronize { secondary_fired ? 2 : 1 }
        break if drained >= fired && results.empty?

        _tag, index, result = results.pop
        drained += 1

        case result
        when :failed
          # A fast primary error must hedge immediately (do not wait for the
          # timer). The gate keeps the secondary at-most-once.
          fire_secondary.call if index.zero?
        when :not_modified
          saw_not_modified = true
        else # :updated -> a real install
          installed = true
          # If the PRIMARY just won inside the hedge window, close the gate so a
          # racing timer can never fire the secondary — the cold-standby promise.
          suppress_secondary.call if index.zero?
          break
        end
      end

      # Stop the timer if it is still sleeping (already-fired is harmless).
      hedge_timer.kill if hedge_timer.alive?

      # Failover observability (qfg-41nh.18): if the secondary leg was actually
      # spawned this cycle, the hedge fired (the primary was slow past the hedge
      # delay or errored fast). Recorded once per cycle regardless of which leg's
      # payload won the reject-older guard. Read under the gate — the flag is
      # written under it by fire_secondary, which may run on the timer thread.
      hedged = gate.synchronize { secondary_spawned }
      @failover_aggregator&.record_hedge_fired if hedged

      return :updated if installed
      return :not_modified if saw_not_modified

      :failed
    end

    def hedge_delay_ms
      if @options.respond_to?(:config_fetch_hedge_delay_ms) && @options.config_fetch_hedge_delay_ms
        @options.config_fetch_hedge_delay_ms
      else
        Quonfig::Options::DEFAULT_CONFIG_FETCH_HEDGE_DELAY_MS
      end
    end

    def hedge_abort_ms
      if @options.respond_to?(:config_fetch_hedge_abort_ms) && @options.config_fetch_hedge_abort_ms
        @options.config_fetch_hedge_abort_ms
      else
        Quonfig::Options::DEFAULT_CONFIG_FETCH_HEDGE_ABORT_MS
      end
    end

    def config_fetch_timeout_ms
      @options.respond_to?(:config_fetch_timeout_ms) ? @options.config_fetch_timeout_ms : nil
    end

    def host_of(url)
      uri = URI(url.to_s)
      uri.host ? "#{uri.host}:#{uri.port}" : url.to_s
    rescue URI::InvalidURIError
      ''
    end

    def fetch_from(source, index = nil, timeout_ms: nil, statuses: nil, cycle_log: nil, leg_errors: nil)
      cycle_log ||= CycleLog.new(@logger, :normal)
      note = ->(msg) { leg_errors[index || 0] = msg.to_s[0, 200] if leg_errors }
      # qfg-7h5d.1.9 / .1.14: bound this single per-leg attempt so a hung upstream
      # aborts (Faraday::TimeoutError, caught below as :failed). On the hedged
      # path the caller passes config_fetch_hedge_abort_ms; on the sequential /
      # single-URL path it passes config_fetch_timeout_ms.
      conn = Quonfig::HttpConnection.new(source, @options.sdk_key, timeout_ms: timeout_ms)
      headers = {}
      # Per-leg ETag: snapshot this leg's slot before the request (no lock held
      # during the network wait).
      etag = etag_for(index)
      headers['If-None-Match'] = etag if etag
      response = conn.get(CONFIGS_PATH, headers)
      statuses[index || 0] = response.status.to_i if statuses

      case response.status
      when 200
        new_etag = response.headers['ETag'] || response.headers['etag']
        envelope = parse_envelope(response.body)
        result = install_envelope(envelope, source: source, source_index: index)
        # Write this leg's ETag back AFTER the response (per-leg, race-free).
        # Exception (qfg-9dxb.9): an ignored gen<=0 payload keeps the previous
        # ETag. Its ETag is the git sha, and the server may later repair the
        # generation for the SAME sha; remembering it would 304 that repair.
        ignored_unversioned = result == :not_modified && extract_generation(envelope.meta || {}) <= 0
        set_etag_for(index, new_etag) unless ignored_unversioned
        # install_envelope returns :not_modified when the reject-older guard drops
        # an equal/older payload — surface that so the caller doesn't double-count.
        result == :not_modified ? :not_modified : :updated
      when 304
        @logger.debug "Configs not modified (304) from #{source}"
        :not_modified
      when 401, 403
        note.call("HTTP #{response.status} (SDK key rejected)")
        cycle_log.log(:warn, "Config fetch rejected (#{response.status}) from #{source}: #{short_body(response)}", auth: true)
        :failed
      else
        note.call("HTTP #{response.status}")
        cycle_log.log(:info, "Config fetch failed: status #{response.status} from #{source}",
                      auth: AUTH_STATUSES.include?(response.status.to_i))
        :failed
      end
    rescue NonEnvelopeError => e
      note.call("non-envelope 200 (#{e.message})")
      # qfg-9dxb.3: a non-envelope 200 is a leg error, NOT an install — the
      # hedge/failover proceeds and this leg's ETag is never stored (so a junk
      # 200 cannot pin itself through later 304s).
      cycle_log.log(:warn, "Config fetch from #{source} returned a non-envelope 200 (#{e.message}); treating as a failed leg")
      :failed
    rescue Quonfig::ConfigShape::AllInvalidError => e
      note.call(e.message)
      # qfg-krjt: a payload with no loadable config is a leg error, so it can
      # never install as an empty workspace.
      cycle_log.log(:warn, "Config fetch from #{source}: #{e.message}; treating as a failed leg")
      :failed
    rescue Faraday::ConnectionFailed => e
      note.call(e.message)
      @logger.debug "Connection failure fetching configs from #{source}: #{e.message}"
      :failed
    rescue StandardError => e
      note.call("#{e.class}: #{e.message}")
      cycle_log.log(:warn, "Unexpected error fetching configs from #{source}: #{e.message}")
      :failed
    end

    def etag_for(index)
      @etag_mutex.synchronize { @etags[index || 0] }
    end

    def set_etag_for(index, value)
      @etag_mutex.synchronize { @etags[index || 0] = value }
    end

    # Raised by #parse_envelope for a 200 whose body is not a config envelope
    # (qfg-9dxb.3). Caught in #fetch_from as a leg error.
    class NonEnvelopeError < StandardError; end

    def parse_envelope(body)
      data = body.is_a?(String) ? JSON.parse(body) : body
      raise NonEnvelopeError, 'missing meta.version' unless Quonfig::ConfigEnvelope.wire_envelope?(data)

      meta = data['meta'] || {}
      # Skip one malformed config, keep the rest (qfg-krjt). Raises
      # ConfigShape::AllInvalidError when none is loadable.
      configs = Quonfig::ConfigShape.filter(data['configs'] || [], logger: @logger, version: meta['version'])
      Quonfig::ConfigEnvelope.new(configs: configs, meta: meta)
    end

    def short_body(response)
      return '' if response.body.nil?

      str = response.body.to_s
      str.length > 200 ? "#{str[0, 200]}..." : str
    end

    def install_envelope(envelope, source:, source_index: nil)
      meta = envelope.meta || {}
      incoming_gen = extract_generation(meta)

      @install_mutex.synchronize do
        # Reject-older install guard (canonical ordering, §5f; mirrors sdk-go
        # shouldInstall). The rule:
        #   - fresh client (nothing installed yet)  -> install, whatever arrives
        #   - incoming generation <= 0 (unversioned) -> install ONLY if the held
        #     generation is 0 (the client has never held a real generation)
        #   - otherwise -> install iff incoming strictly exceeds held
        # A same-generation snapshot is a no-op (no store churn, no install-count
        # bump, no resolved-from change) so a duplicate leg never flaps an
        # established client, and an OLDER snapshot (a stale secondary reached on
        # failover) is dropped so the client never regresses. Reject-older is the
        # whole rule — no source ranking; a newer primary landing late heals
        # forward automatically. Applies on every network install path (initial
        # fetch, failover/poll fetch, SSE snapshot, SSE update, fallback poller);
        # datadir install bypasses this (it is the local source of truth and goes
        # through Client#apply_datadir_envelope).
        #
        # Unversioned payloads (qfg-9dxb.9): the pre-watermark servers that sent
        # gen 0 on every payload are long gone. Today gen 0 comes only from a
        # server whose git store is damaged (rev-count failed) — the least
        # trustworthy source — so it must not override a held real generation.
        # A client that has only ever seen gen 0 (e.g. `qfg serve`) keeps
        # installing each gen 0 payload.
        unless should_install?(incoming_gen)
          if incoming_gen <= 0
            # Unversioned payload while a real generation is held: not provably
            # older (it carries no ordering info), so a silent no-op — NOT
            # counted as guardRejected.
            @logger.debug "Unversioned payload ignored: held generation #{@held_generation} (source=#{source})"
            return :not_modified
          end

          if incoming_gen < @held_generation
            @logger.debug "Reject-older guard: dropping incoming generation #{incoming_gen} < held #{@held_generation} (source=#{source})"
            # Failover observability (qfg-41nh.18): count the guard rejection.
            # This single guard covers BOTH the HTTP config-fetch path and the
            # SSE message path (apply_envelope) — every network install funnels
            # here. Only a STRICTLY older payload is counted (qfg-rr5b): that is
            # the one thing `guardRejected` is meant to report, "a leg tried to
            # move us backwards", which is what the sdk_failover dashboard panel
            # is for.
            @failover_aggregator&.record_guard_rejected
          else
            # Equal generation: a re-delivery of the envelope we already hold, and
            # a silent no-op (qfg-rr5b). Two server behaviors produce it in normal
            # steady state — api-delivery's SSE `sendInitialConfig` re-sends the
            # current envelope on every connect regardless of the Last-Event-Id
            # we send, and a config poll on an empty per-leg ETag slot (a
            # fresh transport, a reconnect, the fallback poller's engage fetch)
            # returns a full 200 at the same generation. Counting those as
            # `guardRejected` made a healthy client report failover activity from
            # init alone. Not installed, not counted — but still :not_modified, so
            # the caller's liveness stamp is unchanged.
            @logger.debug "Same-generation re-delivery: ignoring incoming generation #{incoming_gen} (source=#{source})"
          end
          return :not_modified
        end

        # Update internal tracking map (for legacy callers / introspection).
        next_map = Concurrent::Map.new
        envelope.configs.each do |cfg|
          key = config_key(cfg)
          next if key.nil?

          next_map[key] = { source: source, config: cfg }
        end
        @api_config = next_map

        @version = meta['version'] || meta[:version] || @version
        @environment_id = meta['environment'] || meta[:environment] || @environment_id

        # Replace the live store first, then advance the generation
        # (qfg-goi1.10.2). An interrupt part-way through the store write
        # (Thread#raise, Timeout) then leaves the held generation where it
        # was, so the same-generation redelivery that follows installs again
        # and repairs the store instead of being ignored as a duplicate.
        #
        # The new config set is built off to the side and swapped in with one
        # reference write (qfg-i86q), so a concurrent lookup never sees a flag
        # from this envelope with a segment from the last one, or a key that
        # is momentarily absent.
        unless @store.nil?
          next_configs = {}
          envelope.configs.each do |cfg|
            key = config_key(cfg)
            next if key.nil?

            next_configs[key] = cfg
          end
          @store.replace_all(next_configs)
        end

        # qfg-9dxb.3 Fix A: an unversioned install (generation <= 0) carries no
        # ordering info and must never LOWER a positive held generation. Under
        # the qfg-9dxb.9 rule it only installs when held is nil/0 anyway, so
        # this keeps held at 0 there; a fresh client seeds off it as usual.
        @held_generation = incoming_gen if @held_generation.nil? || incoming_gen.positive?
        @install_count += 1
        @resolved_from_index = source_index unless source_index.nil?
        # Failover observability (qfg-41nh.18): record which leg served this
        # successful HTTP install (source_index 0 = primary, > 0 = secondary).
        # SSE / datadir installs pass source_index nil and are ignored by the
        # aggregator, so they are never counted.
        @failover_aggregator&.record_resolved_from(source_index)
      end
    end

    # The install decision for a network payload (see #install_envelope).
    def should_install?(incoming_gen)
      return true if @held_generation.nil?
      return @held_generation.zero? if incoming_gen <= 0

      incoming_gen > @held_generation
    end

    # Read Meta.generation (qfg-7h5d.1.1) — the monotonic per-branch commit
    # counter the backend stamps on every envelope. Absent/garbage → 0 (an old
    # backend that doesn't emit it, or fixture mode with no FIXTURE_GENERATION).
    def extract_generation(meta)
      g = meta['generation'] || meta[:generation]
      g.is_a?(Numeric) ? g.to_i : 0
    end

    def config_key(cfg)
      return cfg['key'] || cfg[:key] if cfg.is_a?(Hash)

      cfg.respond_to?(:key) ? cfg.key : nil
    end
  end
end
