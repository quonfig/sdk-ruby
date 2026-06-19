# frozen_string_literal: true

require 'json'

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

    # +store+: the Quonfig::ConfigStore to populate on successful fetch.
    # +options+: a Quonfig::Options instance (supplies sdk_key + config_api_urls).
    # +logger+: optional logger override (defaults to module LOG).
    #
    # Backward compat: callers that pass a single +base_client+ (mock client
    # used by tests that expects `.options`) are still supported.
    def initialize(store_or_base_client, options = nil, logger: nil)
      if options.nil? && store_or_base_client.respond_to?(:options)
        # Legacy shape: ConfigLoader.new(base_client)
        @options = store_or_base_client.options
        @store = nil
      else
        @store = store_or_base_client
        @options = options
      end

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
      urls = Array(@options.config_api_urls)
      return :failed if urls.empty?

      # Single leg (or no secondary configured): no hedge, just fetch on the
      # calling thread under the SEQUENTIAL per-URL timeout (config_fetch_timeout_ms
      # is unchanged and still governs any non-hedged path). Preserves the
      # synchronous, single-request-per-call shape the legacy/mock callers depend
      # on.
      return fetch_from(urls[0], 0, timeout_ms: config_fetch_timeout_ms) if urls.length < 2

      fetch_hedged(urls)
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
    def fetch_hedged(urls)
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

      run_leg = lambda do |index|
        Thread.new do
          result = begin
            fetch_from(urls[index], index, timeout_ms: abort_ms)
          rescue StandardError => e
            @logger.debug "Hedge leg #{index} failed: #{e.class}: #{e.message}"
            :failed
          end
          results.push([:done, index, result])
        end
      end

      fire_secondary = lambda do
        spawn = gate.synchronize do
          next false if secondary_fired

          secondary_fired = true
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

    def fetch_from(source, index = nil, timeout_ms: nil)
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

      case response.status
      when 200
        new_etag = response.headers['ETag'] || response.headers['etag']
        envelope = parse_envelope(response.body)
        result = install_envelope(envelope, source: source, source_index: index)
        # Write this leg's ETag back AFTER the response (per-leg, race-free).
        set_etag_for(index, new_etag)
        # install_envelope returns :not_modified when the reject-older guard drops
        # an equal/older payload — surface that so the caller doesn't double-count.
        result == :not_modified ? :not_modified : :updated
      when 304
        @logger.debug "Configs not modified (304) from #{source}"
        :not_modified
      when 401, 403
        @logger.warn "Config fetch rejected (#{response.status}) from #{source}: #{short_body(response)}"
        :failed
      else
        @logger.info "Config fetch failed: status #{response.status} from #{source}"
        :failed
      end
    rescue Faraday::ConnectionFailed => e
      @logger.debug "Connection failure fetching configs from #{source}: #{e.message}"
      :failed
    rescue StandardError => e
      @logger.warn "Unexpected error fetching configs from #{source}: #{e.message}"
      :failed
    end

    def etag_for(index)
      @etag_mutex.synchronize { @etags[index || 0] }
    end

    def set_etag_for(index, value)
      @etag_mutex.synchronize { @etags[index || 0] = value }
    end

    def parse_envelope(body)
      data = body.is_a?(String) ? JSON.parse(body) : body
      Quonfig::ConfigEnvelope.new(
        configs: data['configs'] || [],
        meta: data['meta'] || {}
      )
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
        # Reject-older install guard (canonical ordering, §5f). A fresh client
        # (no held generation) seeds off whatever arrives first — even an older
        # or gen-0 snapshot. An established client installs ONLY when the incoming
        # generation strictly advances the held one: a same-generation snapshot is
        # a no-op (no store churn, no install-count bump, no resolved-from change)
        # so a duplicate leg never flaps an established client, and an OLDER
        # snapshot (a stale secondary reached on failover) is dropped so the client
        # never regresses. Reject-older is the whole rule — no source ranking; a
        # newer primary landing late heals forward automatically. Applies on every
        # network install path (initial fetch, failover/poll fetch, SSE snapshot,
        # SSE update, fallback poller); datadir install bypasses this (it is the
        # local source of truth and goes through Client#apply_datadir_envelope).
        unless @held_generation.nil? || incoming_gen > @held_generation
          @logger.debug "Reject-older guard: dropping incoming generation #{incoming_gen} <= held #{@held_generation} (source=#{source})"
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

        @held_generation = incoming_gen
        @install_count += 1
        @resolved_from_index = source_index unless source_index.nil?

        # Replace the live store atomically.
        return if @store.nil?

        new_keys = next_map.keys.to_set
        old_keys = @store.keys.to_set
        # Drop keys that disappeared server-side.
        (old_keys - new_keys).each { |k| @store.delete(k) } if @store.respond_to?(:delete)

        envelope.configs.each do |cfg|
          key = config_key(cfg)
          next if key.nil?

          @store.set(key, cfg)
        end
      end
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
