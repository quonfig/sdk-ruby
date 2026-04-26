# frozen_string_literal: true

module Quonfig
  # Public-API resolver: looks up a config by key in a ConfigStore and runs
  # it through an Evaluator against a Context.
  #
  #   store     = Quonfig::ConfigStore.new(configs_hash)
  #   evaluator = Quonfig::Evaluator.new(store)
  #   resolver  = Quonfig::Resolver.new(store, evaluator)
  #   result    = resolver.get('my.flag', context)
  #
  # Mirrors the sdk-node pattern so integration tests (qfg-dk6.22-24) can
  # drive evaluation without constructing a full Client. For the full
  # production read path (with config_loader, SSE updates, telemetry), see
  # Quonfig::ConfigResolver — the two coexist during the JSON migration.
  class Resolver
    TRUE_VALUES = %w[true 1 t yes].freeze

    attr_reader :store, :evaluator
    attr_accessor :project_env_id

    def initialize(store, evaluator)
      @store = store
      @evaluator = evaluator
    end

    def raw(key)
      @store.get(key)
    end

    def get(key, context = nil)
      config = raw(key)
      return nil unless config

      eval_result = @evaluator.evaluate_config(config, context, resolver: self)
      return nil if eval_result.nil?

      resolved_value = resolve_value(eval_result.value, config, context)
      EvalResult.new(value: resolved_value, rule_index: eval_result.rule_index, config: config)
    end

    # Post-evaluation value resolution. Mirrors sdk-node Resolver#resolveValue
    # and sdk-go resolver.Resolve:
    # - "provided" + ENV_VAR  → read ENV[lookup], coerce to config's valueType
    # - confidential + decryptWith → look up the key config, decrypt
    # - everything else passes through unchanged
    def resolve_value(value, config, context = nil)
      return nil if value.nil?

      type = vget(value, :type, 'type')

      if type == 'provided'
        return resolve_provided(value, config)
      end

      confidential = vget(value, :confidential, 'confidential')
      decrypt_with = vget(value, :decryptWith, 'decryptWith', :decrypt_with, 'decrypt_with')
      return resolve_decryption(value, config, context, decrypt_with) if confidential && decrypt_with && !decrypt_with.to_s.empty?

      value
    end

    # Integration shims for code that expects a ConfigResolver. Keep these
    # narrow; the real ConfigResolver still owns the production hot path.
    def symbolize_json_names?
      false
    end

    private

    def vget(hash, *keys)
      return nil if hash.nil?

      keys.each do |k|
        return hash[k] if hash.is_a?(Hash) && hash.key?(k)
      end
      nil
    end

    def config_key(config)
      return nil if config.nil?

      vget(config, :key, 'key')
    end

    def config_value_type(config)
      return nil if config.nil?

      vget(config, :value_type, 'value_type', 'valueType', :valueType)
    end

    def resolve_provided(value, config)
      provided = vget(value, :value, 'value')
      return value if provided.nil?

      source = vget(provided, :source, 'source')
      lookup = vget(provided, :lookup, 'lookup')
      return value if source != 'ENV_VAR' || lookup.nil? || lookup.to_s.empty?

      env_value = ENV[lookup.to_s]
      if env_value.nil?
        raise Quonfig::Errors::MissingEnvVarError,
              %(Environment variable "#{lookup}" not set for config "#{config_key(config)}")
      end

      value_type = config_value_type(config)
      coerced = coerce_env_value(env_value, value_type, config, lookup)
      {
        'type' => coerced_value_type(value_type),
        'value' => coerced
      }
    end

    # Recursively resolve the decryption-key config (it may itself be a
    # provided ENV_VAR), then AES-GCM decrypt the value with that key.
    def resolve_decryption(value, config, context, decrypt_with)
      key_cfg = @store.get(decrypt_with)
      raise Quonfig::Error, %(Decryption key config "#{decrypt_with}" not found) if key_cfg.nil?

      key_match = @evaluator.evaluate_config(key_cfg, context, resolver: self)
      raise Quonfig::Error, %(Decryption key config "#{decrypt_with}" did not match) if key_match.nil?

      resolved_key = resolve_value(key_match.value, key_cfg, context)
      secret_key = vget(resolved_key, :value, 'value').to_s
      raise Quonfig::Error, %(Decryption key from "#{decrypt_with}" is empty) if secret_key.empty?

      ciphertext = vget(value, :value, 'value').to_s
      begin
        plaintext = Quonfig::Encryption.new(secret_key).decrypt(ciphertext)
      rescue StandardError => e
        raise Quonfig::Error, %(Decryption failed for config "#{config_key(config)}": #{e.message})
      end

      {
        'type' => 'string',
        'value' => plaintext,
        'confidential' => true
      }
    end

    # Coerce a raw env var string to the SDK type declared by the config.
    # Matches sdk-node coerceValue (string/int/double/bool/string_list)
    # and sdk-go coerceValue (string/int/double/bool). Anything else falls
    # through as a string.
    def coerce_env_value(env_value, value_type, config, lookup)
      case value_type
      when 'string', nil, ''
        env_value
      when 'int'
        Integer(env_value, 10)
      when 'double'
        Float(env_value)
      when 'bool'
        TRUE_VALUES.include?(env_value.downcase)
      when 'string_list'
        env_value.split(/\s*,\s*/)
      when 'duration'
        env_value
      else
        env_value
      end
    rescue ArgumentError, TypeError
      raise Quonfig::Errors::EnvVarParseError.new(env_value, config, lookup)
    end

    def coerced_value_type(value_type)
      case value_type
      when 'int'         then 'int'
      when 'double'      then 'double'
      when 'bool'        then 'bool'
      when 'string_list' then 'string_list'
      else 'string'
      end
    end
  end
end
