# frozen_string_literal: true

# Ruby types mirroring the JSON delivery protocol defined in
# sdk-node/src/types.ts. Field names are snake_case per Ruby convention;
# callers parsing JSON fixtures (camelCase) are responsible for the mapping.
# All Structs use keyword_init so omitted fields default to nil.
module Quonfig
  Value = Struct.new(:type, :value, :confidential, :decrypt_with, keyword_init: true)

  Criterion = Struct.new(:property_name, :operator, :value_to_match, keyword_init: true)

  Rule = Struct.new(:criteria, :value, keyword_init: true)

  RuleSet = Struct.new(:rules, keyword_init: true)

  Environment = Struct.new(:id, :rules, keyword_init: true)

  Meta = Struct.new(:version, :environment, :workspace_id, keyword_init: true)

  ConfigResponse = Struct.new(
    :id,
    :key,
    :type,
    :value_type,
    :send_to_client_sdk,
    :default,
    :environment,
    keyword_init: true
  )

  WeightedValue = Struct.new(:weight, :value, keyword_init: true)

  WeightedValuesData = Struct.new(:weighted_values, :hash_by_property_name, keyword_init: true)

  SchemaData = Struct.new(:schema_type, :schema, keyword_init: true)

  ProvidedData = Struct.new(:source, :lookup, keyword_init: true)

  WorkspaceEnvironment = Struct.new(:id, :rules, keyword_init: true)

  WorkspaceConfigDocument = Struct.new(
    :id,
    :key,
    :type,
    :value_type,
    :send_to_client_sdk,
    :default,
    :environments,
    keyword_init: true
  )

  QuonfigDatadirEnvironments = Struct.new(:environments, keyword_init: true)

  # ConfigEnvelope is already defined in lib/quonfig/config_envelope.rb with
  # the same members (:configs, :meta). It is required from lib/quonfig.rb.
end
