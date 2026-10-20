# frozen_string_literal: true

# AUTO-GENERATED from integration-test-data/tests/eval/get_or_raise.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'
require 'stringio'
require 'webrick'

class TestGetOrRaise < Minitest::Test
  def init_failure_client(on_init_failure, api_urls, api_status, init_timeout_ms)
    servers = []
    if api_status.positive?
      api_urls = Array.new(2) do
        server = WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new(StringIO.new), AccessLog: [])
        server.mount_proc('/') { |_req, res| res.status = api_status }
        Thread.new { server.start }
        servers << server
        "http://127.0.0.1:#{server.config[:Port]}"
      end
    end
    opts = { sdk_key: 'itd-init-failure', api_urls: api_urls, init_timeout_ms: init_timeout_ms,
             enable_sse: false, enable_polling: false, enable_quonfig_user_context: false,
             context_upload_mode: :none, collect_evaluation_summaries: false }
    opts[:on_init_failure] = on_init_failure unless on_init_failure.nil?
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    client = nil
    err = nil
    begin
      client = Quonfig::Client.new(**opts)
    rescue StandardError => e
      err = e
    end
    elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
    [client, err, elapsed_ms, servers]
  end

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

  # init fails by default when every delivery leg refuses the connection
  def test_init_fails_by_default_when_every_delivery_leg_refuses_the_connection
    client, err, elapsed_ms, servers = init_failure_client(nil, ['http://127.0.0.1:1', 'http://127.0.0.1:2'], 0, 500)
    refute_nil err, 'Client.new must raise (on_init_failure default = fail)'
    assert_nil client, 'on_init_failure fail returns no client'
    assert_kind_of Quonfig::Errors::InitializationError, err
    refute_kind_of Quonfig::Errors::InitializationTimeoutError, err, 'reason unavailable, not the init timeout'
    assert_operator elapsed_ms, :<, 5000
    $logs = nil
  ensure
    client&.stop
    servers&.each(&:shutdown)
  end

  # init with on_init_failure fail raises when every delivery leg refuses the connection
  def test_init_with_on_init_failure_fail_raises_when_every_delivery_leg_refuses_the_connection
    client, err, elapsed_ms, servers = init_failure_client(:fail, ['http://127.0.0.1:1', 'http://127.0.0.1:2'], 0, 500)
    refute_nil err, 'Client.new must raise (on_init_failure fail)'
    assert_nil client, 'on_init_failure fail returns no client'
    assert_kind_of Quonfig::Errors::InitializationError, err
    refute_kind_of Quonfig::Errors::InitializationTimeoutError, err, 'reason unavailable, not the init timeout'
    assert_operator elapsed_ms, :<, 5000
    $logs = nil
  ensure
    client&.stop
    servers&.each(&:shutdown)
  end

  # init with on_init_failure fail raises the init timeout when every delivery leg hangs
  def test_init_with_on_init_failure_fail_raises_the_init_timeout_when_every_delivery_leg_hangs
    client, err, elapsed_ms, servers = init_failure_client(:fail, ['http://192.0.2.1:1', 'http://192.0.2.1:2'], 0, 200)
    refute_nil err, 'Client.new must raise (on_init_failure fail)'
    assert_nil client, 'on_init_failure fail returns no client'
    assert_kind_of Quonfig::Errors::InitializationError, err
    assert_kind_of Quonfig::Errors::InitializationTimeoutError, err
    assert_operator elapsed_ms, :<, 2000
    $logs = nil
  ensure
    client&.stop
    servers&.each(&:shutdown)
  end

  # init with on_init_failure fail raises at once when every delivery leg answers 401
  def test_init_with_on_init_failure_fail_raises_at_once_when_every_delivery_leg_answers_401
    client, err, elapsed_ms, servers = init_failure_client(:fail, [], 401, 8000)
    refute_nil err, 'Client.new must raise (on_init_failure fail)'
    assert_nil client, 'on_init_failure fail returns no client'
    assert_kind_of Quonfig::Errors::InitializationError, err
    refute_kind_of Quonfig::Errors::InitializationTimeoutError, err, 'reason unauthorized, not the init timeout'
    assert_operator elapsed_ms, :<, 4000
    $logs = nil
  ensure
    client&.stop
    servers&.each(&:shutdown)
  end

  # get_or_raise returns the default after init continues past refused delivery legs
  def test_get_or_raise_returns_the_default_after_init_continues_past_refused_delivery_legs
    client, err, _elapsed_ms, servers = init_failure_client(:continue, ['http://127.0.0.1:1', 'http://127.0.0.1:2'], 0, 500)
    assert_nil err, 'on_init_failure continue: Client.new must return'
    refute_nil client
    actual = client.get_or_raise('any-key', default: 'DEFAULT')
    assert_equal 'DEFAULT', actual, 'client.get_or_raise(any-key, default: DEFAULT)'
    $logs = nil
  ensure
    client&.stop
    servers&.each(&:shutdown)
  end

  # get_or_raise raises missing_default after init continues past refused delivery legs
  def test_get_or_raise_raises_missing_default_after_init_continues_past_refused_delivery_legs
    client, err, _elapsed_ms, servers = init_failure_client(:continue, ['http://127.0.0.1:1', 'http://127.0.0.1:2'], 0, 500)
    assert_nil err, 'on_init_failure continue: Client.new must return'
    refute_nil client
    assert_raises(Quonfig::Errors::MissingDefaultError) { client.get_or_raise('any-key') }
    $logs = nil
  ensure
    client&.stop
    servers&.each(&:shutdown)
  end

  # deprecated on_init_failure raise behaves as fail when every delivery leg refuses the connection
  def test_deprecated_on_init_failure_raise_behaves_as_fail_when_every_delivery_leg_refuses_the_connection
    client, err, elapsed_ms, servers = init_failure_client(:raise, ['http://127.0.0.1:1', 'http://127.0.0.1:2'], 0, 500)
    refute_nil err, 'Client.new must raise (on_init_failure raise)'
    assert_nil client, 'on_init_failure fail returns no client'
    assert_kind_of Quonfig::Errors::InitializationError, err
    refute_kind_of Quonfig::Errors::InitializationTimeoutError, err, 'reason unavailable, not the init timeout'
    assert_operator elapsed_ms, :<, 5000
    $logs = nil
  ensure
    client&.stop
    servers&.each(&:shutdown)
  end

  # deprecated on_init_failure return behaves as continue when every delivery leg refuses the connection
  def test_deprecated_on_init_failure_return_behaves_as_continue_when_every_delivery_leg_refuses_the_connection
    client, err, _elapsed_ms, servers = init_failure_client(:return, ['http://127.0.0.1:1', 'http://127.0.0.1:2'], 0, 500)
    assert_nil err, 'on_init_failure continue: Client.new must return'
    refute_nil client
    assert_raises(Quonfig::Errors::MissingDefaultError) { client.get_or_raise('any-key') }
    $logs = nil
  ensure
    client&.stop
    servers&.each(&:shutdown)
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

  # coercion error for an int env var names the variable and never its value
  def test_coercion_error_for_an_int_env_var_names_the_variable_and_never_its_value
    IntegrationTestHelpers.with_env({ 'QUONFIG_ITD_SECRET_ENV' => 'postgres://admin:hunter2@db' }) do
      client = IntegrationTestHelpers.build_client
      error = assert_raises(Quonfig::Errors::EnvVarParseError) { client.get_or_raise('provided.secret.not.an.int') }
      assert_includes error.message, 'environment variable "QUONFIG_ITD_SECRET_ENV" cannot be converted to int for config "provided.secret.not.an.int"'
      refute_includes error.message, 'hunter2'
      refute_includes error.message, 'postgres://'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # coercion error for a double env var names the variable and never its value
  def test_coercion_error_for_a_double_env_var_names_the_variable_and_never_its_value
    IntegrationTestHelpers.with_env({ 'QUONFIG_ITD_SECRET_ENV' => 'postgres://admin:hunter2@db' }) do
      client = IntegrationTestHelpers.build_client
      error = assert_raises(Quonfig::Errors::EnvVarParseError) { client.get_or_raise('provided.secret.not.a.double') }
      assert_includes error.message, 'environment variable "QUONFIG_ITD_SECRET_ENV" cannot be converted to double for config "provided.secret.not.a.double"'
      refute_includes error.message, 'hunter2'
      refute_includes error.message, 'postgres://'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
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
