# frozen_string_literal: true

module Quonfig
  class ConfigValueUnwrapper
    LOG = Quonfig::InternalLogger.new(self)
    CONFIDENTIAL_PREFIX = "*****"
    attr_reader :weighted_value_index

    def initialize(config_value, resolver, weighted_value_index = nil)
      @config_value = config_value
      @resolver = resolver
      @weighted_value_index = weighted_value_index
    end

    def reportable_wrapped_value
      if @config_value.confidential || @config_value.decrypt_with&.length&.positive?
        # Unique hash for differentiation
        Quonfig::ConfigValueWrapper.wrap("#{CONFIDENTIAL_PREFIX}#{Digest::MD5.hexdigest(unwrap)[0, 5]}")
      else
        @config_value
      end
    end

    def reportable_value
      Quonfig::ConfigValueUnwrapper.new(reportable_wrapped_value, @resolver, @weighted_value_index).unwrap
    end

    def raw_config_value
      @config_value
    end

    # this will return the actual value of confidential, use reportable_value unless you need it
    def unwrap(raw_json: false)
      raw = case @config_value.type
            when :int, :string, :double, :bool, :log_level
              @config_value.public_send(@config_value.type)
            when :string_list
              @config_value.string_list.values
            when :duration
              Quonfig::Duration.new(@config_value.duration.definition)
            when :json
              if raw_json
                @config_value.json.json
              else
                JSON.parse(@config_value.json.json, symbolize_names: @resolver.symbolize_json_names?)
              end
            else
              LOG.error "Unknown type: #{@config_value.type}"
              raise "Unknown type: #{@config_value.type}"
            end
      if @config_value.has_decrypt_with?
        decryption_key = @resolver.get(@config_value.decrypt_with)&.unwrapped_value
        if decryption_key.nil?
          LOG.warn "No value for decryption key #{@config_value.decrypt_with} found."
          return ""
        else
          unencrypted = Quonfig::Encryption.new(decryption_key).decrypt(raw)
          return unencrypted
        end
      end

      raw
    end

    def self.deepest_value(config_value, config, context, resolver)
      if config_value&.type == :weighted_values
        value, index = Quonfig::WeightedValueResolver.new(
          config_value.weighted_values.weighted_values,
          config.key,
          context.get(config_value.weighted_values.hash_by_property_name)
        ).resolve

        new(deepest_value(value.value, config, context, resolver).raw_config_value, resolver, index)

      elsif config_value&.type == :provided
        if :ENV_VAR == config_value.provided.source
          raw = ENV[config_value.provided.lookup]
          if raw.nil?
            raise Quonfig::Errors::MissingEnvVarError.new("Missing environment variable #{config_value.provided.lookup}")
          else
            coerced = coerce_into_type(raw, config, config_value.provided.lookup)
            new(Quonfig::ConfigValueWrapper.wrap(coerced, confidential: config_value.confidential), resolver)
          end
        else
          raise "Unknown Provided Source #{config_value.provided.source}"
        end
      else
        new(config_value, resolver)
      end
    end

    # Don't allow env vars to resolve to a value_type other than the config's value_type
    def self.coerce_into_type(value_string, config, env_var_name)
      case config.value_type
      when :INT then Integer(value_string)
      when :DOUBLE then Float(value_string)
      when :STRING then String(value_string)
      when :STRING_LIST then
        maybe_string_list = YAML.load(value_string)
        case maybe_string_list
        when Array
          maybe_string_list
        else
          raise raise Quonfig::Errors::EnvVarParseError.new(value_string, config, env_var_name)
        end
      when :BOOL then
        maybe_bool = YAML.load(value_string)
        case maybe_bool
        when TrueClass, FalseClass
          maybe_bool
        else
          raise Quonfig::Errors::EnvVarParseError.new(value_string, config, env_var_name)
        end
      when :NOT_SET_VALUE_TYPE
        YAML.load(value_string)
      else
        raise Quonfig::Errors::EnvVarParseError.new(value_string, config, env_var_name)
      end
    rescue ArgumentError
      raise Quonfig::Errors::EnvVarParseError.new(value_string, config, env_var_name)
    end
  end
end
