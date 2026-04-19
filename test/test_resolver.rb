# frozen_string_literal: true

require 'test_helper'

# Tests for the new public API trio introduced by qfg-dk6.9:
#   store     = Quonfig::ConfigStore.new(configs_hash)
#   evaluator = Quonfig::Evaluator.new(store)
#   resolver  = Quonfig::Resolver.new(store, evaluator)
#   result    = resolver.get('my.flag', context)
#
# Mirrors the sdk-node pattern so the integration test suite (qfg-dk6.22-24)
# can construct these directly without a full Client.
#
# We deliberately do NOT use PrefabProto — the protobuf gem was dropped in
# qfg-dk6.4 and JSON Criterion types land in qfg-dk6.5 / operators port in
# qfg-dk6.10. These tests use minimal Struct doubles that satisfy the
# duck-typed shape the current CriteriaEvaluator reads.
class TestResolverTrio < Minitest::Test
  CONFIG_KEY = 'my.flag'
  DEFAULT_VALUE = 'default_value'

  FakeConfigValue = Struct.new(:string, :type, :confidential, :decrypt_with) do
    def initialize(string: nil, type: :string, confidential: false, decrypt_with: nil)
      super(string, type, confidential, decrypt_with)
    end
    def has_decrypt_with?; !decrypt_with.nil?; end
  end

  FakeConditionalValue = Struct.new(:criteria, :value, keyword_init: true)
  FakeRow = Struct.new(:project_env_id, :values, keyword_init: true)
  FakeConfig = Struct.new(:key, :rows, :id, :config_type, keyword_init: true)

  def make_default_config(key: CONFIG_KEY, value: DEFAULT_VALUE)
    FakeConfig.new(
      key: key,
      id: 1,
      config_type: :CONFIG,
      rows: [
        FakeRow.new(
          project_env_id: 0,
          values: [
            FakeConditionalValue.new(
              criteria: [],
              value: FakeConfigValue.new(string: value, type: :string)
            )
          ]
        )
      ]
    )
  end

  def base_client
    MockBaseClient.new(Quonfig::Options.new)
  end

  # ---- ConfigStore ------------------------------------------------------

  def test_config_store_constructs_with_hash
    cfg = make_default_config
    store = Quonfig::ConfigStore.new({ CONFIG_KEY => cfg })

    assert_equal cfg, store.get(CONFIG_KEY)
    assert_equal [CONFIG_KEY], store.keys
  end

  def test_config_store_constructs_empty
    store = Quonfig::ConfigStore.new
    assert_nil store.get('missing')
    assert_empty store.keys
  end

  def test_config_store_set_and_get
    store = Quonfig::ConfigStore.new
    cfg = make_default_config
    store.set(CONFIG_KEY, cfg)
    assert_equal cfg, store.get(CONFIG_KEY)
  end

  def test_config_store_all_configs_returns_hash
    cfg = make_default_config
    store = Quonfig::ConfigStore.new({ CONFIG_KEY => cfg })

    all = store.all_configs
    assert_kind_of Hash, all
    assert_equal cfg, all[CONFIG_KEY]
  end

  def test_config_store_all_configs_is_a_copy
    cfg = make_default_config
    store = Quonfig::ConfigStore.new({ CONFIG_KEY => cfg })
    store.all_configs['mutated'] = :nope
    assert_nil store.get('mutated')
  end

  def test_config_store_clear_empties_the_store
    store = Quonfig::ConfigStore.new({ CONFIG_KEY => make_default_config })
    store.clear
    assert_nil store.get(CONFIG_KEY)
    assert_empty store.keys
  end

  # ---- Evaluator --------------------------------------------------------

  def test_evaluator_accepts_store
    store = Quonfig::ConfigStore.new
    Quonfig::Evaluator.new(store, base_client: base_client)
  end

  # ---- Resolver ---------------------------------------------------------

  def test_resolver_raw_returns_config_from_store
    cfg = make_default_config
    store = Quonfig::ConfigStore.new({ CONFIG_KEY => cfg })
    evaluator = Quonfig::Evaluator.new(store, base_client: base_client)
    resolver = Quonfig::Resolver.new(store, evaluator)

    assert_equal cfg, resolver.raw(CONFIG_KEY)
  end

  def test_resolver_raw_returns_nil_for_missing_key
    store = Quonfig::ConfigStore.new
    evaluator = Quonfig::Evaluator.new(store, base_client: base_client)
    resolver = Quonfig::Resolver.new(store, evaluator)

    assert_nil resolver.raw('nope')
  end

  def test_resolver_get_returns_evaluation_for_default_row_with_empty_criteria
    cfg = make_default_config
    store = Quonfig::ConfigStore.new({ CONFIG_KEY => cfg })
    evaluator = Quonfig::Evaluator.new(store, base_client: base_client)
    resolver = Quonfig::Resolver.new(store, evaluator)

    result = resolver.get(CONFIG_KEY, Quonfig::Context.new({}))

    refute_nil result
    assert_kind_of Quonfig::Evaluation, result
    # The raw value goes through Evaluation; the config value we stuffed in
    # is a Struct with .string set, so we can fish it back out here without
    # exercising the full ConfigValueUnwrapper chain.
    assert_equal DEFAULT_VALUE, result.value.string
  end

  def test_resolver_get_returns_nil_for_missing_key
    store = Quonfig::ConfigStore.new
    evaluator = Quonfig::Evaluator.new(store, base_client: base_client)
    resolver = Quonfig::Resolver.new(store, evaluator)

    assert_nil resolver.get('nope', Quonfig::Context.new({}))
  end
end
