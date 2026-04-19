# frozen_string_literal: true

module Quonfig
  class FeatureFlagClient
    LOG = Quonfig::InternalLogger.new(self)
    def initialize(base_client)
      @base_client = base_client
    end

    def feature_is_on?(feature_name)
      feature_is_on_for?(feature_name, {})
    end

    def feature_is_on_for?(feature_name, properties)
      variant = @base_client.config_client.get(feature_name, false, properties)

      is_on?(variant)
    end

    def get(feature_name, properties, default: false)
      value = _get(feature_name, properties)

      value.nil? ? default : value
    end

    private

    def _get(feature_name, properties)
      @base_client.config_client.get(feature_name, nil, properties)
    end

    def is_on?(variant)
      return false if variant.nil?

      return variant if variant == !!variant

      variant.bool
    rescue StandardError
      LOG.info("is_on? methods only work for boolean feature flags variants. This feature flags variant is '#{variant}'. Returning false")
      false
    end
  end
end
