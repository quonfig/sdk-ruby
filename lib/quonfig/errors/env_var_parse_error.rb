# frozen_string_literal: true

module Quonfig
  module Errors
    class EnvVarParseError < Quonfig::Error
      # +stored: true+ marks a malformed stored value (no env var involved);
      # the message then names the stored value rather than a variable.
      def initialize(_env_var, config, env_var_name, stored: false)
        key, value_type =
          if config.is_a?(Hash)
            [config[:key] || config['key'],
             config[:value_type] || config['value_type'] || config['valueType']]
          else
            [config.key, config.value_type]
          end
        # +_env_var+ (the raw value) is deliberately left out of the message:
        # an env var or stored value can be a secret (qfg-goi1.2.11). The
        # wording is the cross-SDK template pinned by integration-test-data
        # (v2026.10.12): it names the variable, the lowercase type and the
        # config key, never the value or a parser message quoting it.
        type_name = value_type.to_s.downcase
        source = stored ? 'stored value' : %(environment variable "#{env_var_name}")
        super(%(#{source} cannot be converted to #{type_name} for config "#{key}"))
      end
    end
  end
end
