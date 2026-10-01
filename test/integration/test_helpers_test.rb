# frozen_string_literal: true

require 'test_helper'
require 'integration/test_helpers'

# Verifies the shared helpers the generated integration tests depend on
# (qfg-2agi.33): the public datadir client, env-var scoping, expected-warning
# filtering, and the real-reporter telemetry path.
class TestIntegrationHelpers < Minitest::Test
  def test_data_dir_is_the_integration_tests_sibling_repo
    assert_equal 'integration-tests', File.basename(IntegrationTestHelpers.data_dir)
    assert Dir.exist?(IntegrationTestHelpers.data_dir),
           "integration-test-data sibling repo must exist at #{IntegrationTestHelpers.data_dir}"
  end

  def test_build_client_is_a_datadir_client_over_the_shared_corpus
    client = IntegrationTestHelpers.build_client

    assert_kind_of Quonfig::Client, client
    assert_includes client.keys, 'my-test-key'
    assert_equal 'my-test-value', client.get_string('my-test-key')
    assert_nil client.telemetry_reporter, 'eval clients must not report telemetry'
  end

  def test_build_client_passes_public_options_through
    client = IntegrationTestHelpers.build_client(global_context: { 'user' => { 'email' => 'test@prefab.cloud' } })

    assert_equal 'override', client.get_string('basic.rule.config')
  end

  def test_env_vars_for_encryption_and_env_lookups_are_set_at_load
    assert_equal 'c87ba22d8662282abe8a0e4651327b579cb64a454ab0f4c170b45b15f049a221',
                 ENV.fetch('PREFAB_INTEGRATION_TEST_ENCRYPTION_KEY', nil)
    # IS_A_NUMBER / NOT_A_NUMBER support the env-var lookup integration tests.
    assert_equal '1234', ENV.fetch('IS_A_NUMBER', nil)
    assert_equal 'not_a_number', ENV.fetch('NOT_A_NUMBER', nil)
    assert_nil ENV.fetch('MISSING_ENV_VAR', nil)
  end

  def test_with_env_sets_and_restores
    ENV['ORIGINAL_PRESENT'] = 'keep-me'
    ENV.delete('ORIGINAL_ABSENT')

    IntegrationTestHelpers.with_env(
      'ORIGINAL_PRESENT' => 'overridden',
      'ORIGINAL_ABSENT' => 'temporary'
    ) do
      assert_equal 'overridden', ENV.fetch('ORIGINAL_PRESENT', nil)
      assert_equal 'temporary',  ENV.fetch('ORIGINAL_ABSENT', nil)
    end

    assert_equal 'keep-me', ENV.fetch('ORIGINAL_PRESENT', nil)
    assert_nil ENV.fetch('ORIGINAL_ABSENT', nil)
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
    assert_nil ENV.fetch('ROLLBACK_ME', nil)
  end

  def test_acknowledge_expected_warnings_keeps_unexpected_lines
    $logs = StringIO.new
    $logs.write("WARN foo is not a valid ISO-8601 duration; returning the default\nWARN something else\n")
    IntegrationTestHelpers.acknowledge_expected_warnings

    assert_equal "WARN something else\n", $logs.string
    $logs = nil
  end

  # The telemetry path flushes the client's REAL reporter into a local sink.
  def test_assert_telemetry_post_reads_the_reporters_post
    sink = IntegrationTestHelpers::TelemetrySink.start
    client = IntegrationTestHelpers.build_telemetry_client(sink)
    returned = { 'brand.new.string' => [client.get_or_raise('brand.new.string')] }
    expected = [{ 'key' => 'brand.new.string', 'type' => 'CONFIG', 'value' => 'hello.world', 'value_type' => 'string',
                  'count' => 1, 'reason' => 1, 'selected_value' => { 'string' => 'hello.world' },
                  'summary' => { 'config_row_index' => 0, 'conditional_value_index' => 0 } }]

    IntegrationTestHelpers.assert_telemetry_post(self, client, sink, :evaluation_summary, expected,
                                                 endpoint: '/api/v1/telemetry', returned: returned)
    refute_empty sink.bodies
  ensure
    client&.stop
    sink&.stop
  end
end
