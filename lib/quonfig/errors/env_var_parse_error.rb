# frozen_string_literal: true

module Quonfig
  module Errors
    class EnvVarParseError < Quonfig::Error
      def initialize(env_var, config, env_var_name)
        super("Evaluating #{config.key} couldn't coerce #{env_var_name} of #{env_var} to #{config.value_type}")
      end
    end
  end
end
