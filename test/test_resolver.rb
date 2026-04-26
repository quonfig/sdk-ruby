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

  def test_resolver_get_raises_missing_default_for_missing_key
    store = Quonfig::ConfigStore.new
    evaluator = Quonfig::Evaluator.new(store, base_client: base_client)
    resolver = Quonfig::Resolver.new(store, evaluator)

    # Resolver.get raises Quonfig::Errors::MissingDefaultError when no
    # config exists for the key (qfg-9x7 alignment with the shared YAML
    # get_or_raise.yaml suite). Client.get catches this and folds it into
    # the on_no_default policy / caller-supplied default.
    assert_raises(Quonfig::Errors::MissingDefaultError) do
      resolver.get('nope', Quonfig::Context.new({}))
    end
  end

  # ---- ENV_VAR provided value resolution (qfg-08q) ---------------------

  # Build a config whose value comes from a `provided` ENV_VAR lookup.
  # value_type drives coercion of the env var string back to the SDK type
  # (mirrors sdk-node/sdk-go behavior).
  def make_provided_config(key:, value_type:, lookup:)
    {
      id: '1',
      key: key,
      type: 'config',
      value_type: value_type,
      send_to_client_sdk: false,
      default: {
        'rules' => [
          {
            'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }],
            'value' => {
              'type' => 'provided',
              'value' => { 'source' => 'ENV_VAR', 'lookup' => lookup }
            }
          }
        ]
      },
      environment: nil
    }
  end

  def with_env(name, value)
    original = ENV[name]
    ENV[name] = value
    yield
  ensure
    if original.nil?
      ENV.delete(name)
    else
      ENV[name] = original
    end
  end

  def build_resolver(cfg)
    store = Quonfig::ConfigStore.new({ cfg[:key] => cfg })
    evaluator = Quonfig::Evaluator.new(store, base_client: base_client)
    Quonfig::Resolver.new(store, evaluator)
  end

  def test_resolver_get_resolves_provided_env_var_as_string
    cfg = make_provided_config(key: 'a.string', value_type: 'string', lookup: 'QFG_TEST_STRING')
    resolver = build_resolver(cfg)

    with_env('QFG_TEST_STRING', 'hello') do
      result = resolver.get('a.string', Quonfig::Context.new({}))
      assert_equal 'hello', result.unwrapped_value
      assert_equal 'string', result.value_type
    end
  end

  def test_resolver_get_resolves_provided_env_var_as_int
    cfg = make_provided_config(key: 'a.number', value_type: 'int', lookup: 'QFG_TEST_INT')
    resolver = build_resolver(cfg)

    with_env('QFG_TEST_INT', '1234') do
      result = resolver.get('a.number', Quonfig::Context.new({}))
      assert_equal 1234, result.unwrapped_value
      assert_equal 'int', result.value_type
    end
  end

  def test_resolver_get_resolves_provided_env_var_as_double
    cfg = make_provided_config(key: 'a.double', value_type: 'double', lookup: 'QFG_TEST_DOUBLE')
    resolver = build_resolver(cfg)

    with_env('QFG_TEST_DOUBLE', '3.14') do
      result = resolver.get('a.double', Quonfig::Context.new({}))
      assert_in_delta 3.14, result.unwrapped_value, 0.0001
      assert_equal 'double', result.value_type
    end
  end

  def test_resolver_get_resolves_provided_env_var_as_bool
    cfg = make_provided_config(key: 'a.bool', value_type: 'bool', lookup: 'QFG_TEST_BOOL')
    resolver = build_resolver(cfg)

    with_env('QFG_TEST_BOOL', 'true') do
      result = resolver.get('a.bool', Quonfig::Context.new({}))
      assert_equal true, result.unwrapped_value
      assert_equal 'bool', result.value_type
    end

    with_env('QFG_TEST_BOOL', 'no') do
      result = resolver.get('a.bool', Quonfig::Context.new({}))
      assert_equal false, result.unwrapped_value
    end
  end

  def test_resolver_get_resolves_provided_env_var_as_string_list
    cfg = make_provided_config(key: 'a.list', value_type: 'string_list', lookup: 'QFG_TEST_LIST')
    resolver = build_resolver(cfg)

    with_env('QFG_TEST_LIST', 'a, b ,c') do
      result = resolver.get('a.list', Quonfig::Context.new({}))
      assert_equal %w[a b c], result.unwrapped_value
      assert_equal 'string_list', result.value_type
    end
  end

  def test_resolver_get_raises_missing_env_var_error_when_unset
    cfg = make_provided_config(key: 'a.missing', value_type: 'string', lookup: 'QFG_DEFINITELY_UNSET')
    resolver = build_resolver(cfg)
    ENV.delete('QFG_DEFINITELY_UNSET')

    err = assert_raises(Quonfig::Errors::MissingEnvVarError) do
      resolver.get('a.missing', Quonfig::Context.new({}))
    end
    assert_match(/QFG_DEFINITELY_UNSET/, err.message)
    assert_match(/a\.missing/, err.message)
  end

  def test_resolver_get_raises_env_var_parse_error_on_bad_int
    cfg = make_provided_config(key: 'a.number', value_type: 'int', lookup: 'QFG_TEST_BAD_INT')
    resolver = build_resolver(cfg)

    with_env('QFG_TEST_BAD_INT', 'not_a_number') do
      err = assert_raises(Quonfig::Errors::EnvVarParseError) do
        resolver.get('a.number', Quonfig::Context.new({}))
      end
      assert_match(/a\.number/, err.message)
      assert_match(/not_a_number/, err.message)
    end
  end

  def test_resolver_get_raises_env_var_parse_error_on_bad_double
    cfg = make_provided_config(key: 'a.double', value_type: 'double', lookup: 'QFG_TEST_BAD_DOUBLE')
    resolver = build_resolver(cfg)

    with_env('QFG_TEST_BAD_DOUBLE', 'not_a_number') do
      assert_raises(Quonfig::Errors::EnvVarParseError) do
        resolver.get('a.double', Quonfig::Context.new({}))
      end
    end
  end
end
