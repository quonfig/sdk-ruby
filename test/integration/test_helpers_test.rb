# frozen_string_literal: true

require 'test_helper'
require 'integration/test_helpers'

# Verifies the shared helper that generated integration tests (qfg-dk6.23/.24)
# depend on: fixture loading, resolver construction, env-var scoping,
# and the assertion helper.
class TestIntegrationHelpers < Minitest::Test
  def test_data_dir_is_the_integration_tests_sibling_repo
    assert_equal 'integration-tests', File.basename(IntegrationTestHelpers.data_dir)
    assert Dir.exist?(IntegrationTestHelpers.data_dir),
           "integration-test-data sibling repo must exist at #{IntegrationTestHelpers.data_dir}"
  end

  def test_build_store_loads_configs_from_subdirs
    store = IntegrationTestHelpers.build_store('get')

    assert_kind_of Quonfig::ConfigStore, store
    refute_empty store.keys, 'build_store should load at least one config'
    assert store.keys.include?('my-test-key'),
           "expected 'my-test-key' in store keys (got #{store.keys.first(5).inspect}...)"
  end

  def test_build_resolver_wires_store_and_evaluator
    store = IntegrationTestHelpers.build_store('get')
    resolver = IntegrationTestHelpers.build_resolver(store)

    assert_kind_of Quonfig::Resolver, resolver
    assert_same store, resolver.store
    assert_kind_of Quonfig::Evaluator, resolver.evaluator
  end

  def test_env_vars_for_encryption_and_env_lookups_are_set_at_load
    assert_equal 'c87ba22d8662282abe8a0e4651327b579cb64a454ab0f4c170b45b15f049a221',
                 ENV['PREFAB_INTEGRATION_TEST_ENCRYPTION_KEY']
    # IS_A_NUMBER / NOT_A_NUMBER support the env-var lookup integration tests.
    assert_equal '1234', ENV['IS_A_NUMBER']
    assert_equal 'not_a_number', ENV['NOT_A_NUMBER']
    assert_nil ENV['MISSING_ENV_VAR']
  end

  def test_with_env_sets_and_restores
    ENV['ORIGINAL_PRESENT'] = 'keep-me'
    ENV.delete('ORIGINAL_ABSENT')

    IntegrationTestHelpers.with_env(
      'ORIGINAL_PRESENT' => 'overridden',
      'ORIGINAL_ABSENT'  => 'temporary'
    ) do
      assert_equal 'overridden', ENV['ORIGINAL_PRESENT']
      assert_equal 'temporary',  ENV['ORIGINAL_ABSENT']
    end

    assert_equal 'keep-me', ENV['ORIGINAL_PRESENT']
    assert_nil ENV['ORIGINAL_ABSENT']
  ensure
    ENV.delete('ORIGINAL_PRESENT')
    ENV.delete('ORIGINAL_ABSENT')
  end

  def test_with_env_restores_after_exception
    ENV.delete('ROLLBACK_ME')
    begin
      IntegrationTestHelpers.with_env('ROLLBACK_ME' => 'set') do
        raise 'boom'
      end
    rescue RuntimeError
      # swallow — we only care that ENV was cleaned up
    end
    assert_nil ENV['ROLLBACK_ME']
  end
end
