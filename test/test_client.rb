# frozen_string_literal: true

require 'test_helper'

# Quonfig::Client wires the JSON stack: ConfigStore + Evaluator + Resolver
# (introduced in qfg-dk6.4-9). These tests drive Client through an injected
# ConfigStore so they never touch the network or the filesystem. The legacy
# protobuf ConfigClient/ConfigResolver path was removed in qfg-dk6.32.
class TestClient < Minitest::Test
  CONFIG_KEY = 'my.flag'

  # ---- Test fixtures -----------------------------------------------------

  # Plain ConfigResponse-shaped hash (mirrors what
  # Quonfig::Datadir.to_config_response and IntegrationTestHelpers emit).
  def make_config(key:, value:, type: 'string', criteria: nil)
    {
      'id' => '1',
      'key' => key,
      'type' => 'config',
      'valueType' => type,
      'sendToClientSdk' => false,
      'default' => {
        'rules' => [
          {
            'criteria' => criteria || [{ 'operator' => 'ALWAYS_TRUE' }],
            'value' => { 'type' => type, 'value' => value }
          }
        ]
      },
      'environment' => nil
    }
  end

  def store_with(*configs)
    store = Quonfig::ConfigStore.new
    configs.each { |c| store.set(c['key'], c) }
    store
  end

  def client_with(store, **options)
    Quonfig::Client.new(Quonfig::Options.new(**options), store: store)
  end

  # ---- Construction ------------------------------------------------------

  def test_constructor_accepts_options_object
    client = client_with(Quonfig::ConfigStore.new)
    assert_kind_of Quonfig::Options, client.options
  end

  def test_constructor_wires_resolver_and_evaluator
    store = Quonfig::ConfigStore.new
    client = Quonfig::Client.new(Quonfig::Options.new, store: store)

    assert_kind_of Quonfig::Resolver, client.resolver
    assert_kind_of Quonfig::Evaluator, client.evaluator
    assert_same store, client.store,
                'Client must use the injected ConfigStore instance'
  end

  def test_instance_hash_is_unique_per_client
    a = client_with(Quonfig::ConfigStore.new)
    b = client_with(Quonfig::ConfigStore.new)
    refute_equal a.instance_hash, b.instance_hash
  end

  # ---- get returns coerced JSON values, not PrefabProto ------------------

  def test_get_returns_string_value
    store = store_with(make_config(key: CONFIG_KEY, value: 'hello'))
    assert_equal 'hello', client_with(store).get(CONFIG_KEY)
  end

  def test_get_returns_int_value
    store = store_with(make_config(key: CONFIG_KEY, value: 42, type: 'int'))
    assert_equal 42, client_with(store).get(CONFIG_KEY)
  end

  def test_get_returns_bool_value
    store = store_with(make_config(key: CONFIG_KEY, value: true, type: 'bool'))
    assert_equal true, client_with(store).get(CONFIG_KEY)
  end

  def test_get_returned_value_is_not_a_prefab_proto
    store = store_with(make_config(key: CONFIG_KEY, value: 'hello'))
    value = client_with(store).get(CONFIG_KEY)

    refute value.respond_to?(:string_list),
           'Client#get must return a plain Ruby value, not a PrefabProto::ConfigValue'
    refute value.is_a?(Hash),
           'Client#get must unwrap to the coerced Ruby value, not the JSON Value hash'
  end

  # ---- Missing key handling ---------------------------------------------

  def test_get_returns_explicit_default_when_key_missing
    store = Quonfig::ConfigStore.new
    assert_equal 'fallback', client_with(store).get('nope', 'fallback')
  end

  def test_get_raises_missing_default_error_by_default
    store = Quonfig::ConfigStore.new
    assert_raises(Quonfig::Errors::MissingDefaultError) do
      client_with(store).get('nope')
    end
  end

  def test_get_returns_nil_when_on_no_default_is_return_nil
    store = Quonfig::ConfigStore.new
    client = client_with(store, on_no_default: Quonfig::Options::ON_NO_DEFAULT::RETURN_NIL)
    assert_nil client.get('nope')
  end

  # ---- enabled? --------------------------------------------------------

  def test_enabled_returns_true_when_value_is_true
    store = store_with(make_config(key: CONFIG_KEY, value: true, type: 'bool'))
    assert client_with(store).enabled?(CONFIG_KEY)
  end

  def test_enabled_returns_false_when_value_is_false
    store = store_with(make_config(key: CONFIG_KEY, value: false, type: 'bool'))
    refute client_with(store).enabled?(CONFIG_KEY)
  end

  def test_enabled_returns_false_for_missing_key
    store = Quonfig::ConfigStore.new
    refute client_with(store).enabled?('nope')
  end

  # ---- defined? + keys --------------------------------------------------

  def test_defined_returns_true_for_known_key
    store = store_with(make_config(key: CONFIG_KEY, value: 'x'))
    assert client_with(store).defined?(CONFIG_KEY)
  end

  def test_defined_returns_false_for_unknown_key
    store = store_with(make_config(key: CONFIG_KEY, value: 'x'))
    refute client_with(store).defined?('absent')
  end

  def test_keys_returns_store_keys
    store = store_with(
      make_config(key: 'a', value: '1'),
      make_config(key: 'b', value: '2')
    )
    assert_equal %w[a b].sort, client_with(store).keys.sort
  end

  # ---- Context: jit context is plain Hash, not PrefabProto::Context ----

  def test_get_accepts_jit_context_as_plain_hash
    cfg = make_config(
      key: CONFIG_KEY,
      value: 'matched',
      criteria: [{
        'operator' => 'PROP_IS_ONE_OF',
        'propertyName' => 'user.role',
        'valueToMatch' => { 'type' => 'string_list', 'value' => ['admin'] }
      }]
    )
    store = store_with(cfg)

    result = client_with(store).get(CONFIG_KEY, 'fallback', user: { 'role' => 'admin' })

    assert_equal 'matched', result
  end

  def test_with_context_returns_bound_client
    bound = client_with(Quonfig::ConfigStore.new).with_context(user: { 'key' => '1' })
    assert_kind_of Quonfig::BoundClient, bound
    assert_equal({ user: { 'key' => '1' } }, bound.context)
  end

  def test_in_context_yields_bound_client_when_block_given
    yielded = nil
    client_with(Quonfig::ConfigStore.new).in_context(user: { 'key' => '1' }) do |bound|
      yielded = bound
    end

    assert_kind_of Quonfig::BoundClient, yielded
    assert_equal({ user: { 'key' => '1' } }, yielded.context)
  end

  def test_global_context_is_merged_into_jit_context
    cfg = make_config(
      key: CONFIG_KEY,
      value: 'admin-value',
      criteria: [{
        'operator' => 'PROP_IS_ONE_OF',
        'propertyName' => 'user.role',
        'valueToMatch' => { 'type' => 'string_list', 'value' => ['admin'] }
      }]
    )
    store = store_with(cfg)
    client = Quonfig::Client.new(
      Quonfig::Options.new(global_context: { user: { 'role' => 'admin' } }),
      store: store
    )

    assert_equal 'admin-value', client.get(CONFIG_KEY, 'fallback')
  end

  def test_jit_context_overrides_global_context_at_the_property_level
    cfg = make_config(
      key: CONFIG_KEY,
      value: 'jit-value',
      criteria: [{
        'operator' => 'PROP_IS_ONE_OF',
        'propertyName' => 'user.role',
        'valueToMatch' => { 'type' => 'string_list', 'value' => ['user'] }
      }]
    )
    store = store_with(cfg)
    client = Quonfig::Client.new(
      Quonfig::Options.new(global_context: { user: { 'role' => 'admin' } }),
      store: store
    )

    # jit overrides global for this single property; keys unique to global preserved
    assert_equal 'jit-value', client.get(CONFIG_KEY, 'fallback', user: { 'role' => 'user' })
  end

  def test_normalize_context_rejects_non_hash_jit_context
    store = Quonfig::ConfigStore.new
    assert_raises(ArgumentError) do
      client_with(store).get('nope', 'fallback', 'not-a-hash')
    end
  end

  # ---- Misc -------------------------------------------------------------

  def test_stop_is_a_noop
    client_with(Quonfig::ConfigStore.new).stop
    pass
  end

  def test_inspect_includes_environment
    client = client_with(Quonfig::ConfigStore.new, environment: 'Production')
    assert_match(/environment="Production"/, client.inspect)
  end

  def test_no_prefab_proto_in_lib_quonfig_source
    # qfg-dk6.32: scrub PrefabProto from the runtime lib path.
    lib_dir = File.expand_path('../lib/quonfig', __dir__)
    offenders = Dir.glob(File.join(lib_dir, '**/*.rb')).select do |path|
      File.read(path).match?(/PrefabProto/)
    end

    assert_empty offenders,
                 "lib/quonfig still references PrefabProto:\n#{offenders.join("\n")}"
  end
end
