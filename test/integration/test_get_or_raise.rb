# frozen_string_literal: true

# AUTO-GENERATED from integration-test-data/tests/eval/get_or_raise.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestGetOrRaise < Minitest::Test
  # get_or_raise can raise an error if value not found
  def test_get_or_raise_can_raise_an_error_if_value_not_found
    client = IntegrationTestHelpers.build_client
    assert_raises(Quonfig::Errors::MissingDefaultError) { client.get_or_raise('my-missing-key') }
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # get_or_raise returns a default value instead of raising
  def test_get_or_raise_returns_a_default_value_instead_of_raising
    client = IntegrationTestHelpers.build_client
    actual = client.get_or_raise('my-missing-key', default: 'DEFAULT')
    assert_equal 'DEFAULT', actual, 'client.get_or_raise(my-missing-key, default: DEFAULT)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # get_or_raise raises the correct error if it doesn't raise on init timeout
  def test_get_or_raise_raises_the_correct_error_if_it_doesn_t_raise_on_init_timeout
    client = nil
    assert_raises(Quonfig::Errors::MissingDefaultError) do
      client = IntegrationTestHelpers.build_network_client(api_url: 'https://app.staging-prefab.cloud', timeout_sec: 0.01, on_init_failure: :return)
      client.get_or_raise('any-key')
    end
    $logs = nil
  ensure
    client&.stop
  end

  # get_or_raise can raise an error if the client does not initialize in time
  def test_get_or_raise_can_raise_an_error_if_the_client_does_not_initialize_in_time
    client = nil
    assert_raises(Quonfig::Errors::InitializationTimeoutError) do
      client = IntegrationTestHelpers.build_network_client(api_url: 'https://app.staging-prefab.cloud', timeout_sec: 0.01, on_init_failure: :raise)
      client.get_or_raise('any-key')
    end
    $logs = nil
  ensure
    client&.stop
  end

  # raises an error if a config is provided by a missing environment variable
  def test_raises_an_error_if_a_config_is_provided_by_a_missing_environment_variable
    client = IntegrationTestHelpers.build_client
    assert_raises(Quonfig::Errors::MissingEnvVarError) { client.get_or_raise('provided.by.missing.env.var') }
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # raises an error if an env-var-provided config cannot be coerced to configured type
  def test_raises_an_error_if_an_env_var_provided_config_cannot_be_coerced_to_configured_type
    client = IntegrationTestHelpers.build_client
    assert_raises(Quonfig::Errors::EnvVarParseError) { client.get_or_raise('provided.not.a.number') }
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # raises an error for decryption failure
  def test_raises_an_error_for_decryption_failure
    client = IntegrationTestHelpers.build_client
    assert_raises(Quonfig::Errors::DecryptionError) { client.get_or_raise('a.broken.secret.config') }
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # raises an error if an env-var-provided duration 30s cannot be coerced
  def test_raises_an_error_if_an_env_var_provided_duration_30s_cannot_be_coerced
    IntegrationTestHelpers.with_env({ 'QUONFIG_ITD_DURATION_30S' => '30s' }) do
      client = IntegrationTestHelpers.build_client
      assert_raises(Quonfig::Errors::EnvVarParseError) { client.get_or_raise('provided.duration.malformed.30s') }
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # raises an error if an env-var-provided duration PT0.5H cannot be coerced
  def test_raises_an_error_if_an_env_var_provided_duration_pt0_5h_cannot_be_coerced
    IntegrationTestHelpers.with_env({ 'QUONFIG_ITD_DURATION_PT0_5H' => 'PT0.5H' }) do
      client = IntegrationTestHelpers.build_client
      assert_raises(Quonfig::Errors::EnvVarParseError) { client.get_or_raise('provided.duration.malformed.PT0.5H') }
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # raises an error if an env-var-provided duration P1DT cannot be coerced
  def test_raises_an_error_if_an_env_var_provided_duration_p1dt_cannot_be_coerced
    IntegrationTestHelpers.with_env({ 'QUONFIG_ITD_DURATION_P1DT' => 'P1DT' }) do
      client = IntegrationTestHelpers.build_client
      assert_raises(Quonfig::Errors::EnvVarParseError) { client.get_or_raise('provided.duration.malformed.P1DT') }
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # raises an error if an env-var-provided duration garbage cannot be coerced
  def test_raises_an_error_if_an_env_var_provided_duration_garbage_cannot_be_coerced
    IntegrationTestHelpers.with_env({ 'QUONFIG_ITD_DURATION_GARBAGE' => 'garbage' }) do
      client = IntegrationTestHelpers.build_client
      assert_raises(Quonfig::Errors::EnvVarParseError) { client.get_or_raise('provided.duration.malformed.garbage') }
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # raises an error if a stored duration 30s cannot be coerced
  def test_raises_an_error_if_a_stored_duration_30s_cannot_be_coerced
    client = IntegrationTestHelpers.build_client
    assert_raises(Quonfig::Errors::EnvVarParseError) { client.get_or_raise('test.duration.malformed.30s') }
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # raises an error if a stored duration PT0.5H cannot be coerced
  def test_raises_an_error_if_a_stored_duration_pt0_5h_cannot_be_coerced
    client = IntegrationTestHelpers.build_client
    assert_raises(Quonfig::Errors::EnvVarParseError) { client.get_or_raise('test.duration.malformed.PT0.5H') }
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # raises an error if a stored duration P1DT cannot be coerced
  def test_raises_an_error_if_a_stored_duration_p1dt_cannot_be_coerced
    client = IntegrationTestHelpers.build_client
    assert_raises(Quonfig::Errors::EnvVarParseError) { client.get_or_raise('test.duration.malformed.P1DT') }
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # raises an error if a stored duration garbage cannot be coerced
  def test_raises_an_error_if_a_stored_duration_garbage_cannot_be_coerced
    client = IntegrationTestHelpers.build_client
    assert_raises(Quonfig::Errors::EnvVarParseError) { client.get_or_raise('test.duration.malformed.garbage') }
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # raises an error if a stored duration empty cannot be coerced
  def test_raises_an_error_if_a_stored_duration_empty_cannot_be_coerced
    client = IntegrationTestHelpers.build_client
    assert_raises(Quonfig::Errors::EnvVarParseError) { client.get_or_raise('test.duration.malformed.empty') }
    IntegrationTestHelpers.acknowledge_expected_warnings
  end
end
