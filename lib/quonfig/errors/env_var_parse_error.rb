# frozen_string_literal: true

module Quonfig
  module Errors
    class EnvVarParseError < Quonfig::Error
      def initialize(env_var, config, env_var_name)
        key, value_type =
          if config.is_a?(Hash)
            [config[:key] || config['key'],
             config[:value_type] || config['value_type'] || config['valueType']]
          else
            [config.key, config.value_type]
          end
        super("Evaluating #{key} couldn't coerce #{env_var_name} of #{env_var} to #{value_type}")
      end
    end
  end
end
