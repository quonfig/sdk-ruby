# frozen_string_literal: true

module Quonfig
  class LocalConfigParser
    class << self
      def parse(key, value, config, file)
        if value.instance_of?(Hash)
          if value['feature_flag']
            config[key] = feature_flag_config(file, key, value)
          elsif value['type'] == 'provided'
            config[key] = provided_config(file, key, value)
          elsif value['decrypt_with'] || value['confidential']
            config[key] = complex_string(file, key, value)
          else
            value.each do |nest_key, nest_value|
              nested_key = "#{key}.#{nest_key}"
              nested_key = key if nest_key == '_'
              parse(nested_key, nest_value, config, file)
            end
          end
        else
          config[key] = {
            source: file,
            match: 'default',
            config: PrefabProto::Config.new(
              config_type: :CONFIG,
              key: key,
              rows: [
                PrefabProto::ConfigRow.new(values: [
                  PrefabProto::ConditionalValue.new(value: value_from(key, value))
                ])
              ]
            )
          }
        end

        config
      end

      def value_from(key, raw)
        case raw
        when String
          if key.to_s.start_with? 'log-level'
            prefab_log_level_resolve = PrefabProto::LogLevel.resolve(raw.upcase.to_sym) || PrefabProto::LogLevel::NOT_SET_LOG_LEVEL
            { log_level: prefab_log_level_resolve }
          else
            { string: raw }
          end
        when Integer
          { int: raw }
        when TrueClass, FalseClass
          { bool: raw }
        when Float
          { double: raw }
        end
      end

      def feature_flag_config(file, key, value)
        criterion = (parse_criterion(value['criterion']) if value['criterion'])

        variant = PrefabProto::ConfigValue.new(value_from(key, value['value']))

        row = PrefabProto::ConfigRow.new(
          values: [
            PrefabProto::ConditionalValue.new(
              criteria: [criterion].compact,
              value: variant
            )
          ]
        )

        raise Quonfig::Error, "Feature flag config `#{key}` #{file} must have a `value`" unless value.key?('value')

        {
          source: file,
          match: key,
          config: PrefabProto::Config.new(
            config_type: :FEATURE_FLAG,
            key: key,
            allowable_values: [variant],
            rows: [row]
          )
        }
      end

      def provided_config(file, key, value_hash)
        value = PrefabProto::ConfigValue.new(provided: PrefabProto::Provided.new(
          source: :ENV_VAR,
          lookup: value_hash["lookup"],
        ),
                                             confidential: value_hash["confidential"],
        )

        row = PrefabProto::ConfigRow.new(
          values: [
            PrefabProto::ConditionalValue.new(
              value: value
            )
          ]
        )

        {
          source: file,
          match: value.provided.lookup,
          config: PrefabProto::Config.new(
            config_type: :CONFIG,
            key: key,
            rows: [row]
          )
        }
      end

      def complex_string(file, key, value_hash)
        value = PrefabProto::ConfigValue.new(
          string: value_hash["value"],
          confidential: value_hash["confidential"],
          decrypt_with: value_hash["decrypt_with"],
        )

        row = PrefabProto::ConfigRow.new(
          values: [
            PrefabProto::ConditionalValue.new(
              value: value
            )
          ]
        )

        {
          source: file,
          config: PrefabProto::Config.new(
            config_type: :CONFIG,
            key: key,
            rows: [row]
          )
        }
      end

      def parse_criterion(criterion)
        PrefabProto::Criterion.new(operator: criterion['operator'],
                                   property_name: criterion['property'],
                                   value_to_match: parse_value_to_match(criterion['values']))
      end

      def parse_value_to_match(values)
        raise "Can't handle #{values}" unless values.instance_of?(Array)

        PrefabProto::ConfigValue.new(string_list: PrefabProto::StringList.new(values: values))
      end
    end
  end
end
