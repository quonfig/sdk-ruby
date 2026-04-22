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
  # fetch per `initialization_timeout_sec`.
  class ConfigLoader
    LOG = Quonfig::InternalLogger.new(self)

    CONFIGS_PATH = '/api/v2/configs'

    attr_reader :etag, :version, :environment_id

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
      Array(@options.config_api_urls).each do |api_url|
        result = fetch_from(api_url)
        return result if result != :failed
      end
      :failed
    end

    # Apply a ConfigEnvelope (from SSE) to the store. Called by the SSE client
    # when a new event arrives.
    def apply_envelope(envelope)
      install_envelope(envelope, source: :sse)
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

    def fetch_from(source)
      conn = Quonfig::HttpConnection.new(source, @options.sdk_key)
      headers = {}
      headers['If-None-Match'] = @etag if @etag
      response = conn.get(CONFIGS_PATH, headers)

      case response.status
      when 200
        new_etag = response.headers['ETag'] || response.headers['etag']
        envelope = parse_envelope(response.body)
        install_envelope(envelope, source: source)
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
      str.length > 200 ? str[0, 200] + '...' : str
    end

    def install_envelope(envelope, source:)
      # Update internal tracking map (for legacy callers / introspection).
      next_map = Concurrent::Map.new
      envelope.configs.each do |cfg|
        key = config_key(cfg)
        next if key.nil?
        next_map[key] = { source: source, config: cfg }
      end
      @api_config = next_map

      meta = envelope.meta || {}
      @version = meta['version'] || meta[:version] || @version
      @environment_id = meta['environment'] || meta[:environment] || @environment_id

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

    def config_key(cfg)
      return cfg['key'] || cfg[:key] if cfg.is_a?(Hash)
      cfg.respond_to?(:key) ? cfg.key : nil
    end
  end
end
