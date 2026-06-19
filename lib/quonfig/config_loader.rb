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

    attr_reader :etag, :version, :environment_id

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
      @etag = nil
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

    # Fetch configs from /api/v2/configs with ETag / If-None-Match caching.
    # On 200 responses, installs the envelope into the attached ConfigStore
    # (if one was provided).
    #
    # Returns one of:
    #   :updated       -- 200 response; store replaced
    #   :not_modified  -- 304 response; store untouched
    #   :failed        -- every configured source failed
    def fetch!
      Array(@options.config_api_urls).each_with_index do |api_url, index|
        result = fetch_from(api_url, index)
        return result if result != :failed
      end
      :failed
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

    def fetch_from(source, index = nil)
      # qfg-7h5d.1.9: bound this single per-URL attempt so a hung upstream aborts
      # fast (Faraday::TimeoutError, caught below as :failed) and the next leg is
      # reached inside the caller's init/poll budget instead of being starved
      # until it.
      conn = Quonfig::HttpConnection.new(
        source, @options.sdk_key,
        timeout_ms: (@options.respond_to?(:config_fetch_timeout_ms) ? @options.config_fetch_timeout_ms : nil)
      )
      headers = {}
      headers['If-None-Match'] = @etag if @etag
      response = conn.get(CONFIGS_PATH, headers)

      case response.status
      when 200
        new_etag = response.headers['ETag'] || response.headers['etag']
        envelope = parse_envelope(response.body)
        install_envelope(envelope, source: source, source_index: index)
        @etag = new_etag
        :updated
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
