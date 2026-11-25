# frozen_string_literal: true

require 'digest'

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
    LOG = Quonfig::InternalLogger.new(self)
    TRUE_VALUES = %w[true 1 t yes].freeze
    # Prefix the eval-summary aggregator stamps onto redacted confidential
    # values before the 5-char MD5 hash. Matches CONFIDENTIAL_PREFIX in
    # ReforgeHQ/sdk-ruby/lib/reforge/config_value_unwrapper.rb so dashboards
    # built against the predecessor wire format keep working.
    CONFIDENTIAL_PREFIX = '*****'

    attr_reader :store, :evaluator
    attr_accessor :project_env_id

    def initialize(store, evaluator)
      @store = store
      @evaluator = evaluator
      # Config keys already warned about a missing hash property (qfg-9dxb.8).
      @hash_missing_warned = Set.new
      @hash_missing_mutex = Mutex.new
    end

    def raw(key)
      @store.get(key)
    end

    # Look up +key+ and evaluate against +context+. Mirrors Quonfig.get_or_raise
    # semantics: if the key is unknown to the store, raise
    # Quonfig::Errors::MissingDefaultError so callers can distinguish "no
    # such config" from "config matched a nil/false value". Tests that want
    # the legacy "return nil if absent" shape can rescue and recover (see
    # IntegrationTestHelpers.assert_resolved, which folds a missing-key
    # raise into the test's expected default).
    # The whole lookup reads one store snapshot (qfg-i86q): the flag and the
    # segments it references all come from the same envelope even if an
    # install lands mid-evaluation.
    def get(key, context = nil)
      return get_unpinned(key, context) unless @store.respond_to?(:pinned)

      @store.pinned { get_unpinned(key, context) }
    end

    # Post-evaluation value resolution. Mirrors sdk-node Resolver#resolveValue
    # and sdk-go resolver.Resolve:
    # - a value of a secret (type "secret", from secrets/) → qf1 decrypt
    # - "provided" + ENV_VAR  → read ENV[lookup], coerce to config's valueType
    # - a value carrying decryptWith → DecryptionError (the old format is no
    #   longer read; spec 13.3 R1)
    # - everything else passes through unchanged
    def resolve_value(value, config, context = nil, &on_weighted_index)
      resolve_value_on_path(value, config, context, [], &on_weighted_index)
    end

    # Integration shims for code that expects a ConfigResolver. Keep these
    # narrow; the real ConfigResolver still owns the production hot path.
    def symbolize_json_names?
      false
    end

    private

    def get_unpinned(key, context)
      config = raw(key)
      raise Quonfig::Errors::MissingDefaultError, key if config.nil?

      eval_result = @evaluator.evaluate_config(config, context, resolver: self)
      return nil if eval_result.nil?

      weighted_index = nil
      hash_missing = []
      selected_variants = []
      resolved_value = resolve_value_on_path(eval_result.value, config, context, [], hash_missing,
                                             selected_variants) do |idx|
        weighted_index = idx
      end
      # Redact from the selected rollout variant, not only the outer
      # weighted_values wrapper (which is never flagged), so a confidential
      # variant never reaches telemetry in plaintext (qfg-goi1.2.39). A
      # secret is always redacted, flagged confidential or not.
      secret = secret_config?(config)
      reportable = redacted_reportable_value(eval_result.value, force: secret) ||
                   redacted_reportable_value(selected_variants.last, force: secret)
      EvalResult.new(
        value: resolved_value,
        rule_index: eval_result.rule_index,
        config: config,
        weighted_value_index: weighted_index,
        reportable_value: reportable,
        hash_property_missing: !hash_missing.empty?
      )
    end

    # resolve_value plus +key_path+ (kept for the call shape; nothing
    # recurses across configs since decryptWith is gone). +hash_missing+, when given,
    # gets an entry for each weighted rollout whose hash property was missing
    # from the context (qfg-9dxb.8). +selected_variants+, when given, gets the
    # stored (pre-resolution) Value of each weighted variant picked, so get()
    # can redact a confidential variant (qfg-goi1.2.39).
    def resolve_value_on_path(value, config, context, key_path, hash_missing = nil, selected_variants = nil,
                              &on_weighted_index)
      return nil if value.nil?

      # A secret's value is decrypted whatever else it carries: the directory
      # (type "secret"), not the value, marks it as encrypted (spec 10.2).
      return resolve_secret(value, config) if secret_config?(config)

      type = vget(value, :type, 'type')

      return resolve_provided(value, config) if type == 'provided'

      if type == 'weighted_values'
        return resolve_weighted(value, config, context, key_path, hash_missing, selected_variants,
                                &on_weighted_index)
      end

      decrypt_with = vget(value, :decryptWith, 'decryptWith', :decrypt_with, 'decrypt_with')
      unless decrypt_with.nil? || decrypt_with.to_s.empty?
        # Spec 13.3 R1: never return old-format ciphertext as a value.
        raise Quonfig::Errors::DecryptionError.new(
          config_key(config),
          'value carries decryptWith (the old secrets format), which this SDK no longer reads; ' \
          'move it to secrets/ as a qf1 secret'
        )
      end

      value
    end

    # If +value+ is confidential or has a decryptWith key, return the
    # `*****<5-hex>` redacted string the eval-summary telemetry aggregator
    # should ship in place of the resolved plaintext. The hash is computed
    # over the raw `value[:value]` (ciphertext when decryptWith is set,
    # plaintext-as-stored when only `confidential: true`) — matches
    # ReforgeHQ/sdk-ruby ConfigValueUnwrapper#reportable_wrapped_value
    # (CONFIDENTIAL_PREFIX + first 5 chars of MD5).
    # +force+ redacts whatever the value's flags say (a secret).
    def redacted_reportable_value(value, force: false)
      return nil if value.nil?

      confidential = vget(value, :confidential, 'confidential')
      decrypt_with = vget(value, :decryptWith, 'decryptWith', :decrypt_with, 'decrypt_with')
      return nil unless force || confidential || (decrypt_with && !decrypt_with.to_s.empty?)

      raw = vget(value, :value, 'value')
      return nil if raw.nil?

      "#{CONFIDENTIAL_PREFIX}#{Digest::MD5.hexdigest(raw.to_s)[0, 5]}"
    end

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

      env_value = ENV.fetch(lookup.to_s, nil)
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

    # Pick a weighted variant. Mirrors sdk-node Resolver#resolveWeightedValues
    # and sdk-go resolveWeightedValues: hash the configured context property
    # (or fall back to a per-call random) into [0,1), then walk the variant
    # weights until cumulative weight >= bucket. Recurses through
    # resolve_value so nested provided/encrypted variants work too.
    #
    # A hash property that is configured but missing from the context (or
    # nil) hashes an empty value, the same bucket as a present "", and warns
    # once per config key (qfg-9dxb.8). With no hash property configured the
    # pick stays random per call.
    def resolve_weighted(value, config, context, key_path, hash_missing = nil, selected_variants = nil,
                         &on_weighted_index)
      payload = vget(value, :value, 'value') || {}
      weighted = vget(payload, :weightedValues, 'weightedValues', :weighted_values, 'weighted_values')
      return value unless weighted.is_a?(Array) && !weighted.empty?

      hash_property = vget(payload, :hashByPropertyName, 'hashByPropertyName',
                           :hash_by_property_name, 'hash_by_property_name')
      hash_value = nil
      if hash_property && context
        ctx_value =
          if context.respond_to?(:get)
            context.get(hash_property.to_s)
          elsif context.is_a?(Hash)
            ctx_obj = Quonfig::Context.new(context)
            ctx_obj.get(hash_property.to_s)
          end
        hash_value = ctx_value.to_s unless ctx_value.nil?
      end

      cfg_key = config_key(config)
      if hash_value.nil? && !hash_property.to_s.empty?
        hash_value = ''
        hash_missing&.push(true)
        warn_hash_property_missing(cfg_key, hash_property)
      end
      picker = Quonfig::WeightedValueResolver.new(weighted, cfg_key, hash_value)
      variant, index = picker.resolve
      on_weighted_index&.call(index)
      variant_value = vget(variant, :value, 'value')
      selected_variants&.push(variant_value)
      resolve_value_on_path(variant_value, config, context, key_path, hash_missing, selected_variants,
                            &on_weighted_index)
    end

    def warn_hash_property_missing(cfg_key, hash_property)
      return unless @hash_missing_mutex.synchronize { @hash_missing_warned.add?(cfg_key) }

      LOG.warn "quonfig: weighted rollout for \"#{cfg_key}\" hashes on \"#{hash_property}\" " \
               'which is missing from context; hashing an empty value instead'
    end

    def secret_config?(config)
      !config.nil? && vget(config, :type, 'type').to_s == 'secret'
    end

    # Decrypt a secret's rule value with the qf1 reader (spec 8), lazily on
    # get. The keyset env var is read here, never at startup, so a missing
    # keyset fails only this value (spec 9.3). The DecryptionError carries the
    # qf1 class, keyset and fingerprints only; its cause is the Qf1::Error,
    # whose text follows the same rules.
    def resolve_secret(value, config)
      stored = vget(value, :value, 'value')
      type = vget(value, :type, 'type')
      begin
        raise Quonfig::Qf1::Error.new('malformed', "a secret's value must have type string, not #{type.to_s[0, 32].inspect}") unless type.to_s == 'string'

        plaintext = Quonfig::Qf1.decrypt(stored, ENV)
      rescue Quonfig::Qf1::Error => e
        raise Quonfig::Errors::DecryptionError.new(config_key(config), e)
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
        raise ArgumentError, 'invalid ISO-8601 duration' unless Quonfig::Duration.valid?(env_value)

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
      # Keep 'duration' so Evaluator#unwrapped_value converts to ms and
      # get() matches the stored path (qfg-2agi.22).
      when 'duration'    then 'duration'
      else 'string'
      end
    end
  end
end
