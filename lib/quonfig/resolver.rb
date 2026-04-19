# frozen_string_literal: true

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
    attr_reader :store, :evaluator
    attr_accessor :project_env_id

    def initialize(store, evaluator)
      @store = store
      @evaluator = evaluator
    end

    def raw(key)
      @store.get(key)
    end

    def get(key, context = nil)
      config = raw(key)
      return nil unless config

      @evaluator.evaluate_config(config, context, resolver: self)
    end

    # Integration shims for code that expects a ConfigResolver. Keep these
    # narrow; the real ConfigResolver still owns the production hot path.
    def symbolize_json_names?
      false
    end
  end
end
