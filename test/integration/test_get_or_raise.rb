# frozen_string_literal: true
#
# AUTO-GENERATED from integration-test-data/tests/eval/get_or_raise.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestGetOrRaise < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store("get_or_raise")
  end

  # get_or_raise can raise an error if value not found
  def test_get_or_raise_can_raise_an_error_if_value_not_found
    resolver = IntegrationTestHelpers.build_resolver(@store)
    ctx = Quonfig::Context.new({})
    assert_raises(Quonfig::Errors::MissingDefaultError) { resolver.get("my-missing-key", ctx) }
  end

  # get_or_raise returns a default value instead of raising
  def test_get_or_raise_returns_a_default_value_instead_of_raising
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_get_with_default(@store, "my-missing-key", {}, "DEFAULT", "DEFAULT")
  end

  # get_or_raise raises the correct error if it doesn't raise on init timeout
  def test_get_or_raise_raises_the_correct_error_if_it_doesn_t_raise_on_init_timeout
    IntegrationTestHelpers.assert_client_construction_raises("any-key", 0.01, "https://app.staging-prefab.cloud", "return", "get_or_raise", Quonfig::Errors::MissingDefaultError)
  end

  # get_or_raise can raise an error if the client does not initialize in time
  def test_get_or_raise_can_raise_an_error_if_the_client_does_not_initialize_in_time
    IntegrationTestHelpers.assert_initialization_timeout_error("any-key", 0.01, "https://app.staging-prefab.cloud", "raise")
  end

  # raises an error if a config is provided by a missing environment variable
  def test_raises_an_error_if_a_config_is_provided_by_a_missing_environment_variable
    resolver = IntegrationTestHelpers.build_resolver(@store)
    ctx = Quonfig::Context.new({})
    assert_raises(Quonfig::Errors::MissingEnvVarError) { resolver.get("provided.by.missing.env.var", ctx) }
  end

  # raises an error if an env-var-provided config cannot be coerced to configured type
  def test_raises_an_error_if_an_env_var_provided_config_cannot_be_coerced_to_configured_type
    resolver = IntegrationTestHelpers.build_resolver(@store)
    ctx = Quonfig::Context.new({})
    assert_raises(Quonfig::Errors::EnvVarParseError) { resolver.get("provided.not.a.number", ctx) }
  end

  # raises an error for decryption failure
  def test_raises_an_error_for_decryption_failure
    resolver = IntegrationTestHelpers.build_resolver(@store)
    ctx = Quonfig::Context.new({})
    assert_raises(Quonfig::Errors::DecryptionError) { resolver.get("a.broken.secret.config", ctx) }
  end
end
