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
  #   <datadir>/log-levels/*.json
  #
  # schemas/ is intentionally excluded — those files are raw JSON Schema
  # documents, not Configs, and SDKs do not consume them (qfg-uzsl).
  #
  # Each <type>/*.json file is a WorkspaceConfigDocument. The loader projects
  # it down to the ConfigResponse shape that the SSE/HTTP delivery path emits,
  # so ConfigStore consumes both transports uniformly.
  module Datadir
    CONFIG_SUBDIRS = %w[configs feature-flags segments log-levels].freeze

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
          path = File.join(dir, filename)
          raw = JSON.parse(File.read(path))
          raise ArgumentError, "[quonfig] config has empty key — file is not a Quonfig Config: #{path}" if raw['key'].nil? || raw['key'].to_s.empty?

          coerce_numeric_values(raw)
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
      environment ||= ENV.fetch('QUONFIG_ENVIRONMENT', nil)

      raise Quonfig::Errors::MissingEnvironmentError if environment.nil? || environment.empty?

      raise ArgumentError, "[quonfig] Datadir is missing quonfig.json: #{quonfig_path}" unless File.exist?(quonfig_path)

      environments = JSON.parse(File.read(quonfig_path)).fetch('environments', [])

      raise Quonfig::Errors::InvalidEnvironmentError.new(environment, environments) if !environments.empty? && !environments.include?(environment)

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

    # Config files store int/double Value fields as JSON strings
    # (`{"type":"int","value":"123"}`). api-delivery normalizes these to real
    # numbers at config-load time (`Value.UnmarshalJSON`), so every envelope it
    # emits over HTTP/SSE already carries JSON numbers. In datadir mode we read
    # the files directly, so we must coerce here to match.
    #
    # Walks the parsed config document in place, coercing every Value node — any
    # Hash with a `type` of `"int"`/`"double"` and a String `value` — to a real
    # number. A generic recursive walk covers `default.rules[].value`,
    # environment rules, `criteria[].valueToMatch`, weighted-value arms, and
    # variants without enumerating each location. On parse failure the original
    # string is left in place (passthrough — never raise).
    def coerce_numeric_values(node)
      case node
      when Hash
        coerce_numeric_value_field(node)
        node.each_value { |child| coerce_numeric_values(child) }
      when Array
        node.each { |child| coerce_numeric_values(child) }
      end
      node
    end

    def coerce_numeric_value_field(hash)
      value = hash['value']
      return unless value.is_a?(String)

      case hash['type']
      when 'int'
        hash['value'] = Integer(value, 10)
      when 'double'
        hash['value'] = Float(value)
      end
    rescue ArgumentError, TypeError
      # Unparseable numeric string — leave the original value untouched.
    end
  end
end
