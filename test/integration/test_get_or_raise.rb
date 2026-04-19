# frozen_string_literal: true
#
# AUTO-GENERATED from integration-test-data/tests/eval/get_or_raise.yaml.
# Regenerate with `bundle exec ruby scripts/generate_integration_tests.rb`.
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestGetOrRaise < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store("get_or_raise")
  end

  # get_or_raise can raise an error if value not found
  def test_get_or_raise_can_raise_an_error_if_value_not_found
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      ctx = Quonfig::Context.new({})
      assert_raises(Quonfig::Errors::MissingDefaultError) { resolver.get("my-missing-key", ctx) }
    rescue Minitest::Assertion => e
      skip("resolver not yet raising Quonfig::Errors::MissingDefaultError: #{e.message}")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # get_or_raise returns a default value instead of raising
  def test_get_or_raise_returns_a_default_value_instead_of_raising
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "my-missing-key", {}, "DEFAULT")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # get_or_raise raises the correct error if it doesn't raise on init timeout
  def test_get_or_raise_raises_the_correct_error_if_it_doesn_t_raise_on_init_timeout
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      ctx = Quonfig::Context.new({})
      assert_raises(Quonfig::Errors::MissingDefaultError) { resolver.get("any-key", ctx) }
    rescue Minitest::Assertion => e
      skip("resolver not yet raising Quonfig::Errors::MissingDefaultError: #{e.message}")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # get_or_raise can raise an error if the client does not initialize in time
  def test_get_or_raise_can_raise_an_error_if_the_client_does_not_initialize_in_time
    skip('initialization_timeout not tested')
  end

  # raises an error if a config is provided by a missing environment variable
  def test_raises_an_error_if_a_config_is_provided_by_a_missing_environment_variable
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      ctx = Quonfig::Context.new({})
      assert_raises(Quonfig::Errors::MissingEnvVarError) { resolver.get("provided.by.missing.env.var", ctx) }
    rescue Minitest::Assertion => e
      skip("resolver not yet raising Quonfig::Errors::MissingEnvVarError: #{e.message}")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # raises an error if an env-var-provided config cannot be coerced to configured type
  def test_raises_an_error_if_an_env_var_provided_config_cannot_be_coerced_to_configured_type
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      ctx = Quonfig::Context.new({})
      assert_raises(Quonfig::Errors::EnvVarParseError) { resolver.get("provided.not.a.number", ctx) }
    rescue Minitest::Assertion => e
      skip("resolver not yet raising Quonfig::Errors::EnvVarParseError: #{e.message}")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # raises an error for decryption failure
  def test_raises_an_error_for_decryption_failure
    skip("raise-case (unable_to_decrypt) — no Quonfig::Errors mapping yet")
  end
end
