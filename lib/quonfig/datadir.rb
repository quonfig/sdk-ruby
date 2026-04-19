# frozen_string_literal: true

require 'json'

module Quonfig
  # Loads a Quonfig workspace from the local filesystem (offline / datadir
  # mode). Mirrors sdk-node/src/datadir.ts.
  #
  # The workspace directory layout matches integration-test-data:
  #   <datadir>/quonfig.json
  #   <datadir>/configs/*.json
  #   <datadir>/feature-flags/*.json
  #   <datadir>/segments/*.json
  #   <datadir>/schemas/*.json
  #   <datadir>/log-levels/*.json
  #
  # Each <type>/*.json file is a WorkspaceConfigDocument. The loader projects
  # it down to the ConfigResponse shape that the SSE/HTTP delivery path emits,
  # so ConfigStore consumes both transports uniformly.
  module Datadir
    CONFIG_SUBDIRS = %w[configs feature-flags segments schemas log-levels].freeze

    module_function

    # Read every config JSON in `datadir`, project to ConfigResponse hashes,
    # and wrap in a ConfigEnvelope. Does no network I/O.
    def load_envelope(datadir, environment = nil)
      env_id = resolve_environment(File.join(datadir, 'quonfig.json'), environment)
      configs = []

      CONFIG_SUBDIRS.each do |subdir|
        dir = File.join(datadir, subdir)
        next unless Dir.exist?(dir)

        Dir.children(dir)
           .select { |name| name.end_with?('.json') }
           .sort
           .each do |filename|
          raw = JSON.parse(File.read(File.join(dir, filename)))
          configs << to_config_response(raw, env_id)
        end
      end

      Quonfig::ConfigEnvelope.new(
        configs: configs,
        meta: { 'version' => "datadir:#{datadir}", 'environment' => env_id }
      )
    end

    # Convenience: load the envelope and populate a fresh ConfigStore.
    def load_store(datadir, environment = nil)
      envelope = load_envelope(datadir, environment)
      store = Quonfig::ConfigStore.new
      envelope.configs.each { |cfg| store.set(cfg['key'], cfg) }
      store
    end

    def resolve_environment(quonfig_path, environment)
      environment ||= ENV['QUONFIG_ENVIRONMENT']

      if environment.nil? || environment.empty?
        raise ArgumentError,
              '[quonfig] Environment required for datadir mode; set the `environment` option or QUONFIG_ENVIRONMENT env var'
      end

      unless File.exist?(quonfig_path)
        raise ArgumentError, "[quonfig] Datadir is missing quonfig.json: #{quonfig_path}"
      end

      environments = JSON.parse(File.read(quonfig_path)).fetch('environments', [])

      if !environments.empty? && !environments.include?(environment)
        raise ArgumentError,
              "[quonfig] Environment \"#{environment}\" not found in workspace; available environments: #{environments.join(', ')}"
      end

      environment
    end

    def to_config_response(raw, env_id)
      environment = Array(raw['environments']).find { |e| e['id'] == env_id }
      type = raw['type']

      {
        'id' => raw['id'] || '',
        'key' => raw['key'],
        'type' => type,
        'valueType' => raw['valueType'],
        'sendToClientSdk' => effective_send_to_client_sdk(type, raw['sendToClientSdk']),
        'default' => raw['default'] || { 'rules' => [] },
        'environment' => environment
      }
    end

    def effective_send_to_client_sdk(type, raw)
      return true if type == 'feature_flag'

      raw || false
    end
  end
end
