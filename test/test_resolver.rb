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

  # qfg-dk6.10 — configs are now plain ConfigResponse-shaped hashes (symbol
  # top-level keys + string keys inside rules/criteria). Matches what
  # Quonfig::Datadir.to_config_response and
  # IntegrationTestHelpers.to_config_response emit.
  def make_default_config(key: CONFIG_KEY, value: DEFAULT_VALUE)
    {
      id: '1',
      key: key,
      type: 'config',
      value_type: 'string',
      send_to_client_sdk: false,
      default: {
        'rules' => [
          {
            'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
            'value' => { 'type' => 'string', 'value' => value }
          }
        ]
      },
      environment: nil
    }
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
    assert_kind_of Quonfig::EvalResult, result
    # The EvalResult exposes both the raw JSON value hash (#value) and the
    # coerced Ruby value (#unwrapped_value). Prefer unwrapped_value for
    # assertions — it mirrors what the real Client returns.
    assert_equal DEFAULT_VALUE, result.unwrapped_value
  end

  def test_resolver_get_returns_nil_for_missing_key
    store = Quonfig::ConfigStore.new
    evaluator = Quonfig::Evaluator.new(store, base_client: base_client)
    resolver = Quonfig::Resolver.new(store, evaluator)

    assert_nil resolver.get('nope', Quonfig::Context.new({}))
  end
end
