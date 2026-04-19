# frozen_string_literal: true

module Quonfig
  # Evaluates configs pulled from a ConfigStore against a Context.
  #
  # Public API shape mirrors sdk-node's Evaluator:
  #   evaluator = Quonfig::Evaluator.new(store)
  #   evaluator.evaluate_config(cfg, context, resolver: resolver)
  #
  # qfg-dk6.9 introduces the class shape. qfg-dk6.10 ports the ~26 criterion
  # operators to the JSON Criterion type; until then per-config criterion
  # evaluation is delegated to Quonfig::CriteriaEvaluator so the operator
  # logic stays in a single place during the migration.
  class Evaluator
    def initialize(store, project_env_id: 0, namespace: nil, base_client: nil)
      @store = store
      @project_env_id = project_env_id
      @namespace = namespace
      @base_client = base_client
    end

    attr_reader :store
    attr_accessor :project_env_id

    def evaluate_config(config, context, resolver:)
      Quonfig::CriteriaEvaluator.new(
        config,
        project_env_id: @project_env_id,
        resolver: resolver,
        namespace: @namespace,
        base_client: @base_client
      ).evaluate(context)
    end
  end
end
