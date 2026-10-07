# frozen_string_literal: true

module Quonfig
  module Errors
    class EnvVarParseError < Quonfig::Error
      def initialize(_env_var, config, env_var_name)
        key, value_type =
          if config.is_a?(Hash)
            [config[:key] || config['key'],
             config[:value_type] || config['value_type'] || config['valueType']]
          else
            [config.key, config.value_type]
          end
        # +_env_var+ (the raw value) is deliberately left out of the message:
        # an env var or stored value can be a secret (qfg-goi1.2.11).
        super("Evaluating #{key} couldn't coerce #{env_var_name} to #{value_type}")
      end
    end
  end
end
