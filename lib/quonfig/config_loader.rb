# frozen_string_literal: true

require 'json'

module Quonfig
  class ConfigLoader
    LOG = Quonfig::InternalLogger.new(self)

    CONFIGS_PATH = '/api/v2/configs'

    attr_reader :etag

    def initialize(base_client)
      @base_client = base_client
      @options = base_client.options
      @api_config = Concurrent::Map.new
      @etag = nil
    end

    # Fetch configs from /api/v2/configs with ETag / If-None-Match caching.
    #
    # Returns one of:
    #   :updated       — 200 response; @api_config and @etag replaced
    #   :not_modified  — 304 response; cache still valid
    #   :failed        — every configured source failed
    def fetch!
      Array(@options.config_api_urls).each do |api_url|
        result = fetch_from(api_url)
        return result if result != :failed
      end
      :failed
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
        replace_api_config(envelope, source)
        @etag = new_etag
        :updated
      when 304
        LOG.debug "Configs not modified (304) from #{source}"
        :not_modified
      else
        LOG.info "Config fetch failed: status #{response.status} from #{source}"
        :failed
      end
    rescue Faraday::ConnectionFailed => e
      LOG.debug "Connection failure fetching configs from #{source}: #{e.message}"
      :failed
    rescue StandardError => e
      LOG.warn "Unexpected error fetching configs from #{source}: #{e.message}"
      :failed
    end

    def parse_envelope(body)
      data = body.is_a?(String) ? JSON.parse(body) : body
      Quonfig::ConfigEnvelope.new(
        configs: data['configs'] || [],
        meta: data['meta'] || {}
      )
    end

    def replace_api_config(envelope, source)
      next_map = Concurrent::Map.new
      envelope.configs.each do |cfg|
        key = config_key(cfg)
        next if key.nil?
        next_map[key] = { source: source, config: cfg }
      end
      @api_config = next_map
    end

    def config_key(cfg)
      return cfg['key'] || cfg[:key] if cfg.is_a?(Hash)
      cfg.respond_to?(:key) ? cfg.key : nil
    end
  end
end
