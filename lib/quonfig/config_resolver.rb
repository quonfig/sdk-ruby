# frozen_string_literal: true

module Quonfig
  class ConfigResolver
    attr_accessor :project_env_id # this will be set by the config_client when it gets an API response
    attr_reader :local_store

    def initialize(base_client, config_loader)
      @lock = Concurrent::ReadWriteLock.new
      @local_store = {}
      @config_loader = config_loader
      @project_env_id = 0 # we don't know this yet, it is set from the API results
      @base_client = base_client
      @on_update = nil
      make_local
    end

    def to_s
      presenter.to_s
    end

    def presenter
      Quonfig::ResolvedConfigPresenter.new(self, @lock, @local_store)
    end

    def keys
      @local_store.keys
    end

    def raw(key)
      @local_store.dig(key, :config)
    end

    def get(key, properties = NO_DEFAULT_PROVIDED)
      @lock.with_read_lock do
        raw_config = raw(key)

        return nil unless raw_config

        evaluate(raw_config, properties)
      end
    end

    def evaluate(config, properties = NO_DEFAULT_PROVIDED)
      Quonfig::CriteriaEvaluator.new(config,
                                    project_env_id: @project_env_id,
                                    resolver: self,
                                    namespace: @base_client.options.namespace,
                                    base_client: @base_client).evaluate(make_context(properties))
    end

    def update
      make_local

      @on_update ? @on_update.call : nil
    end

    def on_update(&block)
      @on_update = block
    end

    def make_context(properties)
      if properties.is_a?(Context)
        properties
      elsif properties == NO_DEFAULT_PROVIDED || properties.nil?
        Context.current
      else
        Context.join(parent: Context.current, hash: properties, id: :jit)
      end
    end

    def symbolize_json_names?
      @base_client.options.symbolize_json_names
    end

    private

    def make_local
      @lock.with_write_lock do
        @local_store = @config_loader.calc_config
      end
    end
  end
end
