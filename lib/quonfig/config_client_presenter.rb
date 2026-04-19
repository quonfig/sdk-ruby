# frozen_string_literal: true

module Quonfig
  class ConfigClientPresenter
    def initialize(size:, source:, project_id:, project_env_id:, sdk_key_id:)
      @size = size
      @source = source
      @project_id = project_id
      @project_env_id = project_env_id
      @sdk_key_id = sdk_key_id
    end

    def to_s
      "Configuration Loaded count=#{@size} source=#{@source} project=#{@project_id} project-env=#{@project_env_id} prefab.sdk-key-id=#{@sdk_key_id}"
    end
  end
end

