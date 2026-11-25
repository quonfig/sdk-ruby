# frozen_string_literal: true

# AUTO-GENERATED from integration-test-data/tests/eval/get.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'digest'
require 'test_helper'
require 'integration/test_helpers'

class TestGet < Minitest::Test
  def qf1_test_keyset(*labels)
    labels.map do |label|
      digest = Digest::SHA256.digest("qf1 test vector private key: #{label}")
      "qf1-priv-#{[digest].pack('m0').tr('+/', '-_').delete('=')}"
    end.join(',')
  end

  # get returns a found value for key
  def test_get_returns_a_found_value_for_key
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('my-test-key')
    assert_equal 'my-test-value', actual, 'client.get_string(my-test-key)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # get returns nil if value not found
  def test_get_returns_nil_if_value_not_found
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_string('my-missing-key')
    assert_nil actual, 'client.get_string(my-missing-key)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # get returns a default for a missing value if a default is given
  def test_get_returns_a_default_for_a_missing_value_if_a_default_is_given
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('my-missing-key', default: 'DEFAULT')
    assert_equal 'DEFAULT', actual, 'client.get_string(my-missing-key, default: DEFAULT)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # get ignores a provided default if the key is found
  def test_get_ignores_a_provided_default_if_the_key_is_found
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('my-test-key', default: 'DEFAULT')
    assert_equal 'my-test-value', actual, 'client.get_string(my-test-key, default: DEFAULT)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # get can return a double
  def test_get_can_return_a_double
    client = IntegrationTestHelpers.build_client
    actual = client.get_float('my-double-key')
    assert_equal 9.95, actual, 'client.get_float(my-double-key)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # get can return a string list
  def test_get_can_return_a_string_list
    client = IntegrationTestHelpers.build_client
    actual = client.get_string_list('my-string-list-key')
    assert_equal %w[a b c], actual, 'client.get_string_list(my-string-list-key)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # can return a value provided by an environment variable
  def test_can_return_a_value_provided_by_an_environment_variable
    IntegrationTestHelpers.with_env({ 'GREETING' => 'hello from the environment' }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_string('greeting.from.env')
      assert_equal 'hello from the environment', actual, 'client.get_string(greeting.from.env)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # can return a value provided by an environment variable after type coercion
  def test_can_return_a_value_provided_by_an_environment_variable_after_type_coercion
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('provided.a.number')
    assert_equal 1234, actual, 'client.get_int(provided.a.number)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # decrypts a qf1 secret
  def test_decrypts_a_qf1_secret
    IntegrationTestHelpers.with_env({ 'QUONFIG_KEYSET' => qf1_test_keyset('QUONFIG_KEYSET/1'), 'QUONFIG_KEYSETX' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST_PROD' => qf1_test_keyset('QUONFIG_KEYSET_TEST_PROD/new', 'QUONFIG_KEYSET_TEST_PROD/old') }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_string('qf1.secret.short')
      assert_equal 'hello', actual, 'client.get_string(qf1.secret.short)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # decrypts a qf1 secret whose value is the empty string
  def test_decrypts_a_qf1_secret_whose_value_is_the_empty_string
    IntegrationTestHelpers.with_env({ 'QUONFIG_KEYSET' => qf1_test_keyset('QUONFIG_KEYSET/1'), 'QUONFIG_KEYSETX' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST_PROD' => qf1_test_keyset('QUONFIG_KEYSET_TEST_PROD/new', 'QUONFIG_KEYSET_TEST_PROD/old') }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_string('qf1.secret.empty')
      assert_equal '', actual, 'client.get_string(qf1.secret.empty)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # decrypts a qf1 secret with multi-byte UTF-8
  def test_decrypts_a_qf1_secret_with_multi_byte_utf_8
    IntegrationTestHelpers.with_env({ 'QUONFIG_KEYSET' => qf1_test_keyset('QUONFIG_KEYSET/1'), 'QUONFIG_KEYSETX' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST_PROD' => qf1_test_keyset('QUONFIG_KEYSET_TEST_PROD/new', 'QUONFIG_KEYSET_TEST_PROD/old') }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_string('qf1.secret.multibyte')
      assert_equal 'pässwörd 日本語 🔑', actual, 'client.get_string(qf1.secret.multibyte)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # decrypts a qf1 secret and keeps its leading U+FEFF
  def test_decrypts_a_qf1_secret_and_keeps_its_leading_u_feff
    IntegrationTestHelpers.with_env({ 'QUONFIG_KEYSET' => qf1_test_keyset('QUONFIG_KEYSET/1'), 'QUONFIG_KEYSETX' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST_PROD' => qf1_test_keyset('QUONFIG_KEYSET_TEST_PROD/new', 'QUONFIG_KEYSET_TEST_PROD/old') }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_string('qf1.secret.leading.bom')
      assert_equal "\ufeffbom stays", actual, 'client.get_string(qf1.secret.leading.bom)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # decrypts a qf1 secret with quotes, backslash, newline, tab and colons
  def test_decrypts_a_qf1_secret_with_quotes_backslash_newline_tab_and_colons
    IntegrationTestHelpers.with_env({ 'QUONFIG_KEYSET' => qf1_test_keyset('QUONFIG_KEYSET/1'), 'QUONFIG_KEYSETX' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST_PROD' => qf1_test_keyset('QUONFIG_KEYSET_TEST_PROD/new', 'QUONFIG_KEYSET_TEST_PROD/old') }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_string('qf1.secret.json.special')
      assert_equal "a\"b\\c\nd\te:f,g qf1:x", actual, 'client.get_string(qf1.secret.json.special)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # decrypts a qf1 secret on the bare QUONFIG_KEYSET keyset
  def test_decrypts_a_qf1_secret_on_the_bare_quonfig_keyset_keyset
    IntegrationTestHelpers.with_env({ 'QUONFIG_KEYSET' => qf1_test_keyset('QUONFIG_KEYSET/1'), 'QUONFIG_KEYSETX' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST_PROD' => qf1_test_keyset('QUONFIG_KEYSET_TEST_PROD/new', 'QUONFIG_KEYSET_TEST_PROD/old') }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_string('qf1.secret.default.keyset')
      assert_equal 'sk_test_default_keyset_value', actual, 'client.get_string(qf1.secret.default.keyset)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # decrypts a qf1 secret encrypted to the second key of a two-key keyset
  def test_decrypts_a_qf1_secret_encrypted_to_the_second_key_of_a_two_key_keyset
    IntegrationTestHelpers.with_env({ 'QUONFIG_KEYSET' => qf1_test_keyset('QUONFIG_KEYSET/1'), 'QUONFIG_KEYSETX' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST_PROD' => qf1_test_keyset('QUONFIG_KEYSET_TEST_PROD/new', 'QUONFIG_KEYSET_TEST_PROD/old') }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_string('qf1.secret.older.key')
      assert_equal 'written before rotation', actual, 'client.get_string(qf1.secret.older.key)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # decrypts the environment-scoped value of a qf1 secret on a second keyset
  def test_decrypts_the_environment_scoped_value_of_a_qf1_secret_on_a_second_keyset
    IntegrationTestHelpers.with_env({ 'QUONFIG_KEYSET' => qf1_test_keyset('QUONFIG_KEYSET/1'), 'QUONFIG_KEYSETX' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST_PROD' => qf1_test_keyset('QUONFIG_KEYSET_TEST_PROD/new', 'QUONFIG_KEYSET_TEST_PROD/old') }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_string('qf1.secret.env.scoped')
      assert_equal 'written with the first public key', actual, 'client.get_string(qf1.secret.env.scoped)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # a qf1 secret shadows a document with the same key in configs
  def test_a_qf1_secret_shadows_a_document_with_the_same_key_in_configs
    IntegrationTestHelpers.with_env({ 'QUONFIG_KEYSET' => qf1_test_keyset('QUONFIG_KEYSET/1'), 'QUONFIG_KEYSETX' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST_PROD' => qf1_test_keyset('QUONFIG_KEYSET_TEST_PROD/new', 'QUONFIG_KEYSET_TEST_PROD/old') }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_string('qf1.secret.shadowed')
      assert_equal 'hello', actual, 'client.get_string(qf1.secret.shadowed)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # qf1 secret on a keyset the environment does not hold returns the default
  def test_qf1_secret_on_a_keyset_the_environment_does_not_hold_returns_the_default
    IntegrationTestHelpers.with_env({ 'QUONFIG_KEYSET' => qf1_test_keyset('QUONFIG_KEYSET/1'), 'QUONFIG_KEYSETX' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST_PROD' => qf1_test_keyset('QUONFIG_KEYSET_TEST_PROD/new', 'QUONFIG_KEYSET_TEST_PROD/old') }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_string('qf1.secret.keyset.missing', default: 'DEFAULT')
      assert_equal 'DEFAULT', actual, 'client.get_string(qf1.secret.keyset.missing, default: DEFAULT)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # qf1 secret on a keyset the environment does not hold with no default returns nil
  def test_qf1_secret_on_a_keyset_the_environment_does_not_hold_with_no_default_returns_nil
    IntegrationTestHelpers.with_env({ 'QUONFIG_KEYSET' => qf1_test_keyset('QUONFIG_KEYSET/1'), 'QUONFIG_KEYSETX' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST_PROD' => qf1_test_keyset('QUONFIG_KEYSET_TEST_PROD/new', 'QUONFIG_KEYSET_TEST_PROD/old') }) do
      client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
      actual = client.get_string('qf1.secret.keyset.missing')
      assert_nil actual, 'client.get_string(qf1.secret.keyset.missing)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # qf1 secret whose fingerprint is not held returns the default
  def test_qf1_secret_whose_fingerprint_is_not_held_returns_the_default
    IntegrationTestHelpers.with_env({ 'QUONFIG_KEYSET' => qf1_test_keyset('QUONFIG_KEYSET/1'), 'QUONFIG_KEYSETX' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST_PROD' => qf1_test_keyset('QUONFIG_KEYSET_TEST_PROD/new', 'QUONFIG_KEYSET_TEST_PROD/old') }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_string('qf1.secret.key.not.held', default: 'DEFAULT')
      assert_equal 'DEFAULT', actual, 'client.get_string(qf1.secret.key.not.held, default: DEFAULT)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # qf1 secret is looked up by keyset and fingerprint, never in another keyset
  def test_qf1_secret_is_looked_up_by_keyset_and_fingerprint_never_in_another_keyset
    IntegrationTestHelpers.with_env({ 'QUONFIG_KEYSET' => qf1_test_keyset('QUONFIG_KEYSET/1'), 'QUONFIG_KEYSETX' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST_PROD' => qf1_test_keyset('QUONFIG_KEYSET_TEST_PROD/new', 'QUONFIG_KEYSET_TEST_PROD/old') }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_string('qf1.secret.cross.keyset', default: 'DEFAULT')
      assert_equal 'DEFAULT', actual, 'client.get_string(qf1.secret.cross.keyset, default: DEFAULT)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # qf1 secret with a tampered header returns the default
  def test_qf1_secret_with_a_tampered_header_returns_the_default
    IntegrationTestHelpers.with_env({ 'QUONFIG_KEYSET' => qf1_test_keyset('QUONFIG_KEYSET/1'), 'QUONFIG_KEYSETX' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST_PROD' => qf1_test_keyset('QUONFIG_KEYSET_TEST_PROD/new', 'QUONFIG_KEYSET_TEST_PROD/old') }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_string('qf1.secret.tampered.header', default: 'DEFAULT')
      assert_equal 'DEFAULT', actual, 'client.get_string(qf1.secret.tampered.header, default: DEFAULT)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # qf1 secret whose keyset name is invalid is refused even when that env var holds its key
  def test_qf1_secret_whose_keyset_name_is_invalid_is_refused_even_when_that_env_var_holds_its_key
    IntegrationTestHelpers.with_env({ 'QUONFIG_KEYSET' => qf1_test_keyset('QUONFIG_KEYSET/1'), 'QUONFIG_KEYSETX' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST_PROD' => qf1_test_keyset('QUONFIG_KEYSET_TEST_PROD/new', 'QUONFIG_KEYSET_TEST_PROD/old') }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_string('qf1.secret.keyset.name.invalid', default: 'DEFAULT')
      assert_equal 'DEFAULT', actual, 'client.get_string(qf1.secret.keyset.name.invalid, default: DEFAULT)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # qf1 secret with a trailing colon is refused
  def test_qf1_secret_with_a_trailing_colon_is_refused
    IntegrationTestHelpers.with_env({ 'QUONFIG_KEYSET' => qf1_test_keyset('QUONFIG_KEYSET/1'), 'QUONFIG_KEYSETX' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST_PROD' => qf1_test_keyset('QUONFIG_KEYSET_TEST_PROD/new', 'QUONFIG_KEYSET_TEST_PROD/old') }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_string('qf1.secret.trailing.colon', default: 'DEFAULT')
      assert_equal 'DEFAULT', actual, 'client.get_string(qf1.secret.trailing.colon, default: DEFAULT)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # qf1 secret whose ephemeral key gives an all-zero shared secret is refused
  def test_qf1_secret_whose_ephemeral_key_gives_an_all_zero_shared_secret_is_refused
    IntegrationTestHelpers.with_env({ 'QUONFIG_KEYSET' => qf1_test_keyset('QUONFIG_KEYSET/1'), 'QUONFIG_KEYSETX' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST_PROD' => qf1_test_keyset('QUONFIG_KEYSET_TEST_PROD/new', 'QUONFIG_KEYSET_TEST_PROD/old') }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_string('qf1.secret.low.order.ephemeral', default: 'DEFAULT')
      assert_equal 'DEFAULT', actual, 'client.get_string(qf1.secret.low.order.ephemeral, default: DEFAULT)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # a value that still carries decryptWith returns the default
  def test_a_value_that_still_carries_decryptwith_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('qf1.legacy.decrypt.with', default: 'DEFAULT')
    assert_equal 'DEFAULT', actual, 'client.get_string(qf1.legacy.decrypt.with, default: DEFAULT)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # a value that still carries decryptWith with no default returns nil
  def test_a_value_that_still_carries_decryptwith_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_string('qf1.legacy.decrypt.with')
    assert_nil actual, 'client.get_string(qf1.legacy.decrypt.with)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # duration 200 ms
  def test_duration_200_ms
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.PT0.2S')
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.PT0.2S)'
    assert_equal 200, actual, 'client.get_duration(test.duration.PT0.2S)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # duration 90S
  def test_duration_90s
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.PT90S')
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.PT90S)'
    assert_equal 90_000, actual, 'client.get_duration(test.duration.PT90S)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # duration 30M
  def test_duration_30m
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.PT30M')
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.PT30M)'
    assert_equal 1_800_000, actual, 'client.get_duration(test.duration.PT30M)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # duration test.duration.P1DT6H2M1.5S
  def test_duration_test_duration_p1dt6h2m1_5s
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.P1DT6H2M1.5S')
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.P1DT6H2M1.5S)'
    assert_equal 108_121_500, actual, 'client.get_duration(test.duration.P1DT6H2M1.5S)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # duration zero PT0S
  def test_duration_zero_pt0s
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.PT0S')
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.PT0S)'
    assert_equal 0, actual, 'client.get_duration(test.duration.PT0S)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # duration zero P0D
  def test_duration_zero_p0d
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.P0D')
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.P0D)'
    assert_equal 0, actual, 'client.get_duration(test.duration.P0D)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # duration days only P2D
  def test_duration_days_only_p2d
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.P2D')
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.P2D)'
    assert_equal 172_800_000, actual, 'client.get_duration(test.duration.P2D)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # duration hours only PT1H
  def test_duration_hours_only_pt1h
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.PT1H')
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.PT1H)'
    assert_equal 3_600_000, actual, 'client.get_duration(test.duration.PT1H)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # duration minutes only PT1M
  def test_duration_minutes_only_pt1m
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.PT1M')
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.PT1M)'
    assert_equal 60_000, actual, 'client.get_duration(test.duration.PT1M)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # duration seconds only PT1S
  def test_duration_seconds_only_pt1s
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.PT1S')
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.PT1S)'
    assert_equal 1000, actual, 'client.get_duration(test.duration.PT1S)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # duration leading zero PT05S
  def test_duration_leading_zero_pt05s
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.PT05S')
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.PT05S)'
    assert_equal 5000, actual, 'client.get_duration(test.duration.PT05S)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # duration hours and minutes PT1H30M
  def test_duration_hours_and_minutes_pt1h30m
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.PT1H30M')
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.PT1H30M)'
    assert_equal 5_400_000, actual, 'client.get_duration(test.duration.PT1H30M)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # duration days and hours P1DT2H
  def test_duration_days_and_hours_p1dt2h
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.P1DT2H')
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.P1DT2H)'
    assert_equal 93_600_000, actual, 'client.get_duration(test.duration.P1DT2H)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # duration one millisecond PT0.001S
  def test_duration_one_millisecond_pt0_001s
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.PT0.001S')
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.PT0.001S)'
    assert_equal 1, actual, 'client.get_duration(test.duration.PT0.001S)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # duration magnitude ceiling P36500D
  def test_duration_magnitude_ceiling_p36500d
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.P36500D')
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.P36500D)'
    assert_equal 3_153_600_000_000, actual, 'client.get_duration(test.duration.P36500D)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # duration rounding PT2.01S
  def test_duration_rounding_pt2_01s
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.PT2.01S')
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.PT2.01S)'
    assert_equal 2010, actual, 'client.get_duration(test.duration.PT2.01S)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # duration rounding PT1.005S
  def test_duration_rounding_pt1_005s
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.PT1.005S')
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.PT1.005S)'
    assert_equal 1005, actual, 'client.get_duration(test.duration.PT1.005S)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # duration rounding half up PT0.0005S
  def test_duration_rounding_half_up_pt0_0005s
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.PT0.0005S')
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.PT0.0005S)'
    assert_equal 1, actual, 'client.get_duration(test.duration.PT0.0005S)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # duration rounding down PT0.0004S
  def test_duration_rounding_down_pt0_0004s
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.PT0.0004S')
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.PT0.0004S)'
    assert_equal 0, actual, 'client.get_duration(test.duration.PT0.0004S)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # json test
  def test_json_test
    client = IntegrationTestHelpers.build_client
    actual = client.get_json('test.json')
    assert_equal({ 'a' => 1, 'b' => 'c' }, actual, 'client.get_json(test.json)')
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # get returns a native json object (not a stringified payload)
  def test_get_returns_a_native_json_object_not_a_stringified_payload
    client = IntegrationTestHelpers.build_client
    actual = client.get_json('test.json')
    assert_equal({ 'a' => 1, 'b' => 'c' }, actual, 'client.get_json(test.json)')
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # list on left side test (1)
  def test_list_on_left_side_test_1
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('left.hand.list.test', context: { 'user' => { 'name' => 'james', 'aka' => %w[happy sleepy] } })
    assert_equal 'correct', actual, 'client.get_string(left.hand.list.test, context: { user => { name => james, aka => %w[happy sleepy] } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # list on left side test (2)
  def test_list_on_left_side_test_2
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('left.hand.list.test', context: { 'user' => { 'name' => 'james', 'aka' => %w[a b] } })
    assert_equal 'default', actual, 'client.get_string(left.hand.list.test, context: { user => { name => james, aka => %w[a b] } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # list on left side test opposite (1)
  def test_list_on_left_side_test_opposite_1
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('left.hand.test.opposite', context: { 'user' => { 'name' => 'james', 'aka' => %w[happy sleepy] } })
    assert_equal 'default', actual, 'client.get_string(left.hand.test.opposite, context: { user => { name => james, aka => %w[happy sleepy] } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # list on left side test (3)
  def test_list_on_left_side_test_3
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('left.hand.test.opposite', context: { 'user' => { 'name' => 'james', 'aka' => %w[a b] } })
    assert_equal 'correct', actual, 'client.get_string(left.hand.test.opposite, context: { user => { name => james, aka => %w[a b] } })'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # env-var-provided duration PT1.5S via get
  def test_env_var_provided_duration_pt1_5s_via_get
    IntegrationTestHelpers.with_env({ 'QUONFIG_ITD_DURATION_PT1_5S' => 'PT1.5S' }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_duration('provided.duration.PT1.5S')
      assert_kind_of Integer, actual, 'client.get_duration(provided.duration.PT1.5S)'
      assert_equal 1500, actual, 'client.get_duration(provided.duration.PT1.5S)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # stored malformed duration 30s returns the default
  def test_stored_malformed_duration_30s_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.malformed.30s', default: 7000)
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.malformed.30s, default: 7000)'
    assert_equal 7000, actual, 'client.get_duration(test.duration.malformed.30s, default: 7000)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # stored malformed duration 30s with no default returns nil
  def test_stored_malformed_duration_30s_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_duration('test.duration.malformed.30s')
    assert_nil actual, 'client.get_duration(test.duration.malformed.30s)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # stored malformed duration PT0.5H returns the default
  def test_stored_malformed_duration_pt0_5h_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.malformed.PT0.5H', default: 7000)
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.malformed.PT0.5H, default: 7000)'
    assert_equal 7000, actual, 'client.get_duration(test.duration.malformed.PT0.5H, default: 7000)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # stored malformed duration PT0.5H with no default returns nil
  def test_stored_malformed_duration_pt0_5h_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_duration('test.duration.malformed.PT0.5H')
    assert_nil actual, 'client.get_duration(test.duration.malformed.PT0.5H)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # stored malformed duration P1DT returns the default
  def test_stored_malformed_duration_p1dt_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.malformed.P1DT', default: 7000)
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.malformed.P1DT, default: 7000)'
    assert_equal 7000, actual, 'client.get_duration(test.duration.malformed.P1DT, default: 7000)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # stored malformed duration P1DT with no default returns nil
  def test_stored_malformed_duration_p1dt_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_duration('test.duration.malformed.P1DT')
    assert_nil actual, 'client.get_duration(test.duration.malformed.P1DT)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # stored malformed duration garbage returns the default
  def test_stored_malformed_duration_garbage_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.malformed.garbage', default: 7000)
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.malformed.garbage, default: 7000)'
    assert_equal 7000, actual, 'client.get_duration(test.duration.malformed.garbage, default: 7000)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # stored malformed duration garbage with no default returns nil
  def test_stored_malformed_duration_garbage_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_duration('test.duration.malformed.garbage')
    assert_nil actual, 'client.get_duration(test.duration.malformed.garbage)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # stored malformed duration empty returns the default
  def test_stored_malformed_duration_empty_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('test.duration.malformed.empty', default: 7000)
    assert_kind_of Integer, actual, 'client.get_duration(test.duration.malformed.empty, default: 7000)'
    assert_equal 7000, actual, 'client.get_duration(test.duration.malformed.empty, default: 7000)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # stored malformed duration empty with no default returns nil
  def test_stored_malformed_duration_empty_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_duration('test.duration.malformed.empty')
    assert_nil actual, 'client.get_duration(test.duration.malformed.empty)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # env-var-provided malformed duration 30s returns the default
  def test_env_var_provided_malformed_duration_30s_returns_the_default
    IntegrationTestHelpers.with_env({ 'QUONFIG_ITD_DURATION_30S' => '30s' }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_duration('provided.duration.malformed.30s', default: 7000)
      assert_kind_of Integer, actual, 'client.get_duration(provided.duration.malformed.30s, default: 7000)'
      assert_equal 7000, actual, 'client.get_duration(provided.duration.malformed.30s, default: 7000)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # env-var-provided malformed duration 30s with no default returns nil
  def test_env_var_provided_malformed_duration_30s_with_no_default_returns_nil
    IntegrationTestHelpers.with_env({ 'QUONFIG_ITD_DURATION_30S' => '30s' }) do
      client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
      actual = client.get_duration('provided.duration.malformed.30s')
      assert_nil actual, 'client.get_duration(provided.duration.malformed.30s)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # env-var-provided malformed duration PT0.5H returns the default
  def test_env_var_provided_malformed_duration_pt0_5h_returns_the_default
    IntegrationTestHelpers.with_env({ 'QUONFIG_ITD_DURATION_PT0_5H' => 'PT0.5H' }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_duration('provided.duration.malformed.PT0.5H', default: 7000)
      assert_kind_of Integer, actual, 'client.get_duration(provided.duration.malformed.PT0.5H, default: 7000)'
      assert_equal 7000, actual, 'client.get_duration(provided.duration.malformed.PT0.5H, default: 7000)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # env-var-provided malformed duration PT0.5H with no default returns nil
  def test_env_var_provided_malformed_duration_pt0_5h_with_no_default_returns_nil
    IntegrationTestHelpers.with_env({ 'QUONFIG_ITD_DURATION_PT0_5H' => 'PT0.5H' }) do
      client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
      actual = client.get_duration('provided.duration.malformed.PT0.5H')
      assert_nil actual, 'client.get_duration(provided.duration.malformed.PT0.5H)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # env-var-provided malformed duration P1DT returns the default
  def test_env_var_provided_malformed_duration_p1dt_returns_the_default
    IntegrationTestHelpers.with_env({ 'QUONFIG_ITD_DURATION_P1DT' => 'P1DT' }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_duration('provided.duration.malformed.P1DT', default: 7000)
      assert_kind_of Integer, actual, 'client.get_duration(provided.duration.malformed.P1DT, default: 7000)'
      assert_equal 7000, actual, 'client.get_duration(provided.duration.malformed.P1DT, default: 7000)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # env-var-provided malformed duration P1DT with no default returns nil
  def test_env_var_provided_malformed_duration_p1dt_with_no_default_returns_nil
    IntegrationTestHelpers.with_env({ 'QUONFIG_ITD_DURATION_P1DT' => 'P1DT' }) do
      client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
      actual = client.get_duration('provided.duration.malformed.P1DT')
      assert_nil actual, 'client.get_duration(provided.duration.malformed.P1DT)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # env-var-provided malformed duration garbage returns the default
  def test_env_var_provided_malformed_duration_garbage_returns_the_default
    IntegrationTestHelpers.with_env({ 'QUONFIG_ITD_DURATION_GARBAGE' => 'garbage' }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_duration('provided.duration.malformed.garbage', default: 7000)
      assert_kind_of Integer, actual, 'client.get_duration(provided.duration.malformed.garbage, default: 7000)'
      assert_equal 7000, actual, 'client.get_duration(provided.duration.malformed.garbage, default: 7000)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # env-var-provided malformed duration garbage with no default returns nil
  def test_env_var_provided_malformed_duration_garbage_with_no_default_returns_nil
    IntegrationTestHelpers.with_env({ 'QUONFIG_ITD_DURATION_GARBAGE' => 'garbage' }) do
      client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
      actual = client.get_duration('provided.duration.malformed.garbage')
      assert_nil actual, 'client.get_duration(provided.duration.malformed.garbage)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # STRING getter on stored int returns the default
  def test_string_getter_on_stored_int_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('getter.contract.int', default: 'DEFAULT')
    assert_equal 'DEFAULT', actual, 'client.get_string(getter.contract.int, default: DEFAULT)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING getter on stored int with no default returns nil
  def test_string_getter_on_stored_int_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_string('getter.contract.int')
    assert_nil actual, 'client.get_string(getter.contract.int)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING getter on stored double returns the default
  def test_string_getter_on_stored_double_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('getter.contract.double', default: 'DEFAULT')
    assert_equal 'DEFAULT', actual, 'client.get_string(getter.contract.double, default: DEFAULT)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING getter on stored double with no default returns nil
  def test_string_getter_on_stored_double_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_string('getter.contract.double')
    assert_nil actual, 'client.get_string(getter.contract.double)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING getter on stored bool returns the default
  def test_string_getter_on_stored_bool_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('getter.contract.bool', default: 'DEFAULT')
    assert_equal 'DEFAULT', actual, 'client.get_string(getter.contract.bool, default: DEFAULT)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING getter on stored bool with no default returns nil
  def test_string_getter_on_stored_bool_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_string('getter.contract.bool')
    assert_nil actual, 'client.get_string(getter.contract.bool)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING getter on stored string_list returns the default
  def test_string_getter_on_stored_string_list_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('getter.contract.string_list', default: 'DEFAULT')
    assert_equal 'DEFAULT', actual, 'client.get_string(getter.contract.string_list, default: DEFAULT)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING getter on stored string_list with no default returns nil
  def test_string_getter_on_stored_string_list_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_string('getter.contract.string_list')
    assert_nil actual, 'client.get_string(getter.contract.string_list)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING getter on stored json returns the default
  def test_string_getter_on_stored_json_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('getter.contract.json', default: 'DEFAULT')
    assert_equal 'DEFAULT', actual, 'client.get_string(getter.contract.json, default: DEFAULT)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING getter on stored json with no default returns nil
  def test_string_getter_on_stored_json_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_string('getter.contract.json')
    assert_nil actual, 'client.get_string(getter.contract.json)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING getter on stored duration returns the default
  def test_string_getter_on_stored_duration_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('getter.contract.duration', default: 'DEFAULT')
    assert_equal 'DEFAULT', actual, 'client.get_string(getter.contract.duration, default: DEFAULT)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING getter on stored duration with no default returns nil
  def test_string_getter_on_stored_duration_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_string('getter.contract.duration')
    assert_nil actual, 'client.get_string(getter.contract.duration)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on stored string returns the default
  def test_int_getter_on_stored_string_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('getter.contract.string', default: 7)
    assert_equal 7, actual, 'client.get_int(getter.contract.string, default: 7)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on stored string with no default returns nil
  def test_int_getter_on_stored_string_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_int('getter.contract.string')
    assert_nil actual, 'client.get_int(getter.contract.string)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on stored double 3.9 returns the default
  def test_int_getter_on_stored_double_3_9_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('getter.contract.double', default: 7)
    assert_equal 7, actual, 'client.get_int(getter.contract.double, default: 7)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on stored double 3.9 with no default returns nil
  def test_int_getter_on_stored_double_3_9_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_int('getter.contract.double')
    assert_nil actual, 'client.get_int(getter.contract.double)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on stored bool returns the default
  def test_int_getter_on_stored_bool_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('getter.contract.bool', default: 7)
    assert_equal 7, actual, 'client.get_int(getter.contract.bool, default: 7)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on stored bool with no default returns nil
  def test_int_getter_on_stored_bool_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_int('getter.contract.bool')
    assert_nil actual, 'client.get_int(getter.contract.bool)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on stored string_list returns the default
  def test_int_getter_on_stored_string_list_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('getter.contract.string_list', default: 7)
    assert_equal 7, actual, 'client.get_int(getter.contract.string_list, default: 7)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on stored string_list with no default returns nil
  def test_int_getter_on_stored_string_list_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_int('getter.contract.string_list')
    assert_nil actual, 'client.get_int(getter.contract.string_list)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on stored json returns the default
  def test_int_getter_on_stored_json_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('getter.contract.json', default: 7)
    assert_equal 7, actual, 'client.get_int(getter.contract.json, default: 7)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on stored json with no default returns nil
  def test_int_getter_on_stored_json_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_int('getter.contract.json')
    assert_nil actual, 'client.get_int(getter.contract.json)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on stored duration returns the default
  def test_int_getter_on_stored_duration_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('getter.contract.duration', default: 7)
    assert_equal 7, actual, 'client.get_int(getter.contract.duration, default: 7)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on stored duration with no default returns nil
  def test_int_getter_on_stored_duration_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_int('getter.contract.duration')
    assert_nil actual, 'client.get_int(getter.contract.duration)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DOUBLE getter on stored string returns the default
  def test_double_getter_on_stored_string_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_float('getter.contract.string', default: 7.5)
    assert_equal 7.5, actual, 'client.get_float(getter.contract.string, default: 7.5)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DOUBLE getter on stored string with no default returns nil
  def test_double_getter_on_stored_string_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_float('getter.contract.string')
    assert_nil actual, 'client.get_float(getter.contract.string)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DOUBLE getter on stored bool returns the default
  def test_double_getter_on_stored_bool_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_float('getter.contract.bool', default: 7.5)
    assert_equal 7.5, actual, 'client.get_float(getter.contract.bool, default: 7.5)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DOUBLE getter on stored bool with no default returns nil
  def test_double_getter_on_stored_bool_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_float('getter.contract.bool')
    assert_nil actual, 'client.get_float(getter.contract.bool)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DOUBLE getter on stored string_list returns the default
  def test_double_getter_on_stored_string_list_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_float('getter.contract.string_list', default: 7.5)
    assert_equal 7.5, actual, 'client.get_float(getter.contract.string_list, default: 7.5)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DOUBLE getter on stored string_list with no default returns nil
  def test_double_getter_on_stored_string_list_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_float('getter.contract.string_list')
    assert_nil actual, 'client.get_float(getter.contract.string_list)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DOUBLE getter on stored json returns the default
  def test_double_getter_on_stored_json_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_float('getter.contract.json', default: 7.5)
    assert_equal 7.5, actual, 'client.get_float(getter.contract.json, default: 7.5)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DOUBLE getter on stored json with no default returns nil
  def test_double_getter_on_stored_json_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_float('getter.contract.json')
    assert_nil actual, 'client.get_float(getter.contract.json)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DOUBLE getter on stored duration returns the default
  def test_double_getter_on_stored_duration_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_float('getter.contract.duration', default: 7.5)
    assert_equal 7.5, actual, 'client.get_float(getter.contract.duration, default: 7.5)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DOUBLE getter on stored duration with no default returns nil
  def test_double_getter_on_stored_duration_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_float('getter.contract.duration')
    assert_nil actual, 'client.get_float(getter.contract.duration)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # BOOLEAN getter on stored string returns the default
  def test_boolean_getter_on_stored_string_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_bool('getter.contract.string', default: false)
    assert_equal false, actual, 'client.get_bool(getter.contract.string, default: false)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # BOOLEAN getter on stored string with no default returns nil
  def test_boolean_getter_on_stored_string_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_bool('getter.contract.string')
    assert_nil actual, 'client.get_bool(getter.contract.string)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # BOOLEAN getter on stored int returns the default
  def test_boolean_getter_on_stored_int_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_bool('getter.contract.int', default: false)
    assert_equal false, actual, 'client.get_bool(getter.contract.int, default: false)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # BOOLEAN getter on stored int with no default returns nil
  def test_boolean_getter_on_stored_int_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_bool('getter.contract.int')
    assert_nil actual, 'client.get_bool(getter.contract.int)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # BOOLEAN getter on stored double returns the default
  def test_boolean_getter_on_stored_double_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_bool('getter.contract.double', default: false)
    assert_equal false, actual, 'client.get_bool(getter.contract.double, default: false)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # BOOLEAN getter on stored double with no default returns nil
  def test_boolean_getter_on_stored_double_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_bool('getter.contract.double')
    assert_nil actual, 'client.get_bool(getter.contract.double)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # BOOLEAN getter on stored string_list returns the default
  def test_boolean_getter_on_stored_string_list_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_bool('getter.contract.string_list', default: false)
    assert_equal false, actual, 'client.get_bool(getter.contract.string_list, default: false)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # BOOLEAN getter on stored string_list with no default returns nil
  def test_boolean_getter_on_stored_string_list_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_bool('getter.contract.string_list')
    assert_nil actual, 'client.get_bool(getter.contract.string_list)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # BOOLEAN getter on stored json returns the default
  def test_boolean_getter_on_stored_json_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_bool('getter.contract.json', default: false)
    assert_equal false, actual, 'client.get_bool(getter.contract.json, default: false)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # BOOLEAN getter on stored json with no default returns nil
  def test_boolean_getter_on_stored_json_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_bool('getter.contract.json')
    assert_nil actual, 'client.get_bool(getter.contract.json)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # BOOLEAN getter on stored duration returns the default
  def test_boolean_getter_on_stored_duration_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_bool('getter.contract.duration', default: false)
    assert_equal false, actual, 'client.get_bool(getter.contract.duration, default: false)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # BOOLEAN getter on stored duration with no default returns nil
  def test_boolean_getter_on_stored_duration_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_bool('getter.contract.duration')
    assert_nil actual, 'client.get_bool(getter.contract.duration)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING_LIST getter on stored string returns the default
  def test_string_list_getter_on_stored_string_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_string_list('getter.contract.string', default: ['DEFAULT'])
    assert_equal ['DEFAULT'], actual, 'client.get_string_list(getter.contract.string, default: [DEFAULT])'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING_LIST getter on stored string with no default returns nil
  def test_string_list_getter_on_stored_string_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_string_list('getter.contract.string')
    assert_nil actual, 'client.get_string_list(getter.contract.string)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING_LIST getter on stored int returns the default
  def test_string_list_getter_on_stored_int_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_string_list('getter.contract.int', default: ['DEFAULT'])
    assert_equal ['DEFAULT'], actual, 'client.get_string_list(getter.contract.int, default: [DEFAULT])'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING_LIST getter on stored int with no default returns nil
  def test_string_list_getter_on_stored_int_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_string_list('getter.contract.int')
    assert_nil actual, 'client.get_string_list(getter.contract.int)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING_LIST getter on stored double returns the default
  def test_string_list_getter_on_stored_double_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_string_list('getter.contract.double', default: ['DEFAULT'])
    assert_equal ['DEFAULT'], actual, 'client.get_string_list(getter.contract.double, default: [DEFAULT])'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING_LIST getter on stored double with no default returns nil
  def test_string_list_getter_on_stored_double_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_string_list('getter.contract.double')
    assert_nil actual, 'client.get_string_list(getter.contract.double)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING_LIST getter on stored bool returns the default
  def test_string_list_getter_on_stored_bool_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_string_list('getter.contract.bool', default: ['DEFAULT'])
    assert_equal ['DEFAULT'], actual, 'client.get_string_list(getter.contract.bool, default: [DEFAULT])'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING_LIST getter on stored bool with no default returns nil
  def test_string_list_getter_on_stored_bool_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_string_list('getter.contract.bool')
    assert_nil actual, 'client.get_string_list(getter.contract.bool)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING_LIST getter on stored json returns the default
  def test_string_list_getter_on_stored_json_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_string_list('getter.contract.json', default: ['DEFAULT'])
    assert_equal ['DEFAULT'], actual, 'client.get_string_list(getter.contract.json, default: [DEFAULT])'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING_LIST getter on stored json with no default returns nil
  def test_string_list_getter_on_stored_json_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_string_list('getter.contract.json')
    assert_nil actual, 'client.get_string_list(getter.contract.json)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING_LIST getter on stored duration returns the default
  def test_string_list_getter_on_stored_duration_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_string_list('getter.contract.duration', default: ['DEFAULT'])
    assert_equal ['DEFAULT'], actual, 'client.get_string_list(getter.contract.duration, default: [DEFAULT])'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING_LIST getter on stored duration with no default returns nil
  def test_string_list_getter_on_stored_duration_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_string_list('getter.contract.duration')
    assert_nil actual, 'client.get_string_list(getter.contract.duration)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # JSON getter on stored string returns the default
  def test_json_getter_on_stored_string_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_json('getter.contract.string', default: { 'default' => true })
    assert_equal({ 'default' => true }, actual, 'client.get_json(getter.contract.string, default: { default => true })')
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # JSON getter on stored string with no default returns nil
  def test_json_getter_on_stored_string_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_json('getter.contract.string')
    assert_nil actual, 'client.get_json(getter.contract.string)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # JSON getter on stored int returns the default
  def test_json_getter_on_stored_int_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_json('getter.contract.int', default: { 'default' => true })
    assert_equal({ 'default' => true }, actual, 'client.get_json(getter.contract.int, default: { default => true })')
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # JSON getter on stored int with no default returns nil
  def test_json_getter_on_stored_int_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_json('getter.contract.int')
    assert_nil actual, 'client.get_json(getter.contract.int)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # JSON getter on stored double returns the default
  def test_json_getter_on_stored_double_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_json('getter.contract.double', default: { 'default' => true })
    assert_equal({ 'default' => true }, actual, 'client.get_json(getter.contract.double, default: { default => true })')
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # JSON getter on stored double with no default returns nil
  def test_json_getter_on_stored_double_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_json('getter.contract.double')
    assert_nil actual, 'client.get_json(getter.contract.double)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # JSON getter on stored bool returns the default
  def test_json_getter_on_stored_bool_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_json('getter.contract.bool', default: { 'default' => true })
    assert_equal({ 'default' => true }, actual, 'client.get_json(getter.contract.bool, default: { default => true })')
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # JSON getter on stored bool with no default returns nil
  def test_json_getter_on_stored_bool_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_json('getter.contract.bool')
    assert_nil actual, 'client.get_json(getter.contract.bool)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # JSON getter on stored string_list returns the default
  def test_json_getter_on_stored_string_list_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_json('getter.contract.string_list', default: { 'default' => true })
    assert_equal({ 'default' => true }, actual, 'client.get_json(getter.contract.string_list, default: { default => true })')
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # JSON getter on stored string_list with no default returns nil
  def test_json_getter_on_stored_string_list_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_json('getter.contract.string_list')
    assert_nil actual, 'client.get_json(getter.contract.string_list)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # JSON getter on stored duration returns the default
  def test_json_getter_on_stored_duration_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_json('getter.contract.duration', default: { 'default' => true })
    assert_equal({ 'default' => true }, actual, 'client.get_json(getter.contract.duration, default: { default => true })')
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # JSON getter on stored duration with no default returns nil
  def test_json_getter_on_stored_duration_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_json('getter.contract.duration')
    assert_nil actual, 'client.get_json(getter.contract.duration)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DURATION getter on stored string returns the default
  def test_duration_getter_on_stored_string_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('getter.contract.string', default: 7000)
    assert_kind_of Integer, actual, 'client.get_duration(getter.contract.string, default: 7000)'
    assert_equal 7000, actual, 'client.get_duration(getter.contract.string, default: 7000)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DURATION getter on stored string with no default returns nil
  def test_duration_getter_on_stored_string_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_duration('getter.contract.string')
    assert_nil actual, 'client.get_duration(getter.contract.string)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DURATION getter on stored int returns the default
  def test_duration_getter_on_stored_int_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('getter.contract.int', default: 7000)
    assert_kind_of Integer, actual, 'client.get_duration(getter.contract.int, default: 7000)'
    assert_equal 7000, actual, 'client.get_duration(getter.contract.int, default: 7000)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DURATION getter on stored int with no default returns nil
  def test_duration_getter_on_stored_int_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_duration('getter.contract.int')
    assert_nil actual, 'client.get_duration(getter.contract.int)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DURATION getter on stored double returns the default
  def test_duration_getter_on_stored_double_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('getter.contract.double', default: 7000)
    assert_kind_of Integer, actual, 'client.get_duration(getter.contract.double, default: 7000)'
    assert_equal 7000, actual, 'client.get_duration(getter.contract.double, default: 7000)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DURATION getter on stored double with no default returns nil
  def test_duration_getter_on_stored_double_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_duration('getter.contract.double')
    assert_nil actual, 'client.get_duration(getter.contract.double)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DURATION getter on stored bool returns the default
  def test_duration_getter_on_stored_bool_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('getter.contract.bool', default: 7000)
    assert_kind_of Integer, actual, 'client.get_duration(getter.contract.bool, default: 7000)'
    assert_equal 7000, actual, 'client.get_duration(getter.contract.bool, default: 7000)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DURATION getter on stored bool with no default returns nil
  def test_duration_getter_on_stored_bool_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_duration('getter.contract.bool')
    assert_nil actual, 'client.get_duration(getter.contract.bool)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DURATION getter on stored string_list returns the default
  def test_duration_getter_on_stored_string_list_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('getter.contract.string_list', default: 7000)
    assert_kind_of Integer, actual, 'client.get_duration(getter.contract.string_list, default: 7000)'
    assert_equal 7000, actual, 'client.get_duration(getter.contract.string_list, default: 7000)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DURATION getter on stored string_list with no default returns nil
  def test_duration_getter_on_stored_string_list_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_duration('getter.contract.string_list')
    assert_nil actual, 'client.get_duration(getter.contract.string_list)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DURATION getter on stored json returns the default
  def test_duration_getter_on_stored_json_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('getter.contract.json', default: 7000)
    assert_kind_of Integer, actual, 'client.get_duration(getter.contract.json, default: 7000)'
    assert_equal 7000, actual, 'client.get_duration(getter.contract.json, default: 7000)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DURATION getter on stored json with no default returns nil
  def test_duration_getter_on_stored_json_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_duration('getter.contract.json')
    assert_nil actual, 'client.get_duration(getter.contract.json)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # BOOLEAN getter on stored string "false" returns the default
  def test_boolean_getter_on_stored_string_false_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_bool('getter.contract.string.false', default: false)
    assert_equal false, actual, 'client.get_bool(getter.contract.string.false, default: false)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # BOOLEAN getter on stored string "false" with no default returns nil
  def test_boolean_getter_on_stored_string_false_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_bool('getter.contract.string.false')
    assert_nil actual, 'client.get_bool(getter.contract.string.false)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # BOOLEAN getter on stored string "false" returns a true default
  def test_boolean_getter_on_stored_string_false_returns_a_true_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_bool('getter.contract.string.false', default: true)
    assert_equal true, actual, 'client.get_bool(getter.contract.string.false, default: true)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # BOOLEAN getter on stored string "true" returns the default
  def test_boolean_getter_on_stored_string_true_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_bool('getter.contract.string.true', default: false)
    assert_equal false, actual, 'client.get_bool(getter.contract.string.true, default: false)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # BOOLEAN getter on stored string "true" with no default returns nil
  def test_boolean_getter_on_stored_string_true_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_bool('getter.contract.string.true')
    assert_nil actual, 'client.get_bool(getter.contract.string.true)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on stored string "3" returns the default
  def test_int_getter_on_stored_string_3_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('getter.contract.string.number', default: 7)
    assert_equal 7, actual, 'client.get_int(getter.contract.string.number, default: 7)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on stored string "3" with no default returns nil
  def test_int_getter_on_stored_string_3_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_int('getter.contract.string.number')
    assert_nil actual, 'client.get_int(getter.contract.string.number)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DOUBLE getter on stored string "3" returns the default
  def test_double_getter_on_stored_string_3_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_float('getter.contract.string.number', default: 7.5)
    assert_equal 7.5, actual, 'client.get_float(getter.contract.string.number, default: 7.5)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DOUBLE getter on stored string "3" with no default returns nil
  def test_double_getter_on_stored_string_3_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_float('getter.contract.string.number')
    assert_nil actual, 'client.get_float(getter.contract.string.number)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DURATION getter on stored string "PT1S" returns the default
  def test_duration_getter_on_stored_string_pt1s_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_duration('getter.contract.string.duration', default: 7000)
    assert_kind_of Integer, actual, 'client.get_duration(getter.contract.string.duration, default: 7000)'
    assert_equal 7000, actual, 'client.get_duration(getter.contract.string.duration, default: 7000)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DURATION getter on stored string "PT1S" with no default returns nil
  def test_duration_getter_on_stored_string_pt1s_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_duration('getter.contract.string.duration')
    assert_nil actual, 'client.get_duration(getter.contract.string.duration)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DOUBLE get on stored int 30 returns 30.0
  def test_double_get_on_stored_int_30_returns_30_0
    client = IntegrationTestHelpers.build_client
    actual = client.get_float('getter.contract.int')
    assert_equal 30, actual, 'client.get_float(getter.contract.int)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT get on stored whole double 3.0 returns 3
  def test_int_get_on_stored_whole_double_3_0_returns_3
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('getter.contract.double.whole')
    assert_equal 3, actual, 'client.get_int(getter.contract.double.whole)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DOUBLE getter on stored int 30 ignores the default
  def test_double_getter_on_stored_int_30_ignores_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_float('getter.contract.int', default: 7.5)
    assert_equal 30, actual, 'client.get_float(getter.contract.int, default: 7.5)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on stored whole double 3.0 ignores the default
  def test_int_getter_on_stored_whole_double_3_0_ignores_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('getter.contract.double.whole', default: 7)
    assert_equal 3, actual, 'client.get_int(getter.contract.double.whole, default: 7)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on stored double 1e300 returns the default
  def test_int_getter_on_stored_double_1e300_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('getter.contract.double.huge', default: 7)
    assert_equal 7, actual, 'client.get_int(getter.contract.double.huge, default: 7)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on stored double 1e300 with no default returns nil
  def test_int_getter_on_stored_double_1e300_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_int('getter.contract.double.huge')
    assert_nil actual, 'client.get_int(getter.contract.double.huge)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on stored double 2^53 (outside the safe int range) returns the default
  def test_int_getter_on_stored_double_2_53_outside_the_safe_int_range_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('getter.contract.double.unsafe', default: 7)
    assert_equal 7, actual, 'client.get_int(getter.contract.double.unsafe, default: 7)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on stored double 2^53 (outside the safe int range) with no default returns nil
  def test_int_getter_on_stored_double_2_53_outside_the_safe_int_range_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_int('getter.contract.double.unsafe')
    assert_nil actual, 'client.get_int(getter.contract.double.unsafe)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on stored malformed int "twelve" returns the default
  def test_int_getter_on_stored_malformed_int_twelve_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('getter.contract.int.malformed', default: 7)
    assert_equal 7, actual, 'client.get_int(getter.contract.int.malformed, default: 7)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on stored malformed int "twelve" with no default returns nil
  def test_int_getter_on_stored_malformed_int_twelve_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_int('getter.contract.int.malformed')
    assert_nil actual, 'client.get_int(getter.contract.int.malformed)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DOUBLE getter on stored malformed double "abc" returns the default
  def test_double_getter_on_stored_malformed_double_abc_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_float('getter.contract.double.malformed', default: 7.5)
    assert_equal 7.5, actual, 'client.get_float(getter.contract.double.malformed, default: 7.5)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # DOUBLE getter on stored malformed double "abc" with no default returns nil
  def test_double_getter_on_stored_malformed_double_abc_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_float('getter.contract.double.malformed')
    assert_nil actual, 'client.get_float(getter.contract.double.malformed)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # INT getter on env-var-provided malformed int "twelve" returns the default
  def test_int_getter_on_env_var_provided_malformed_int_twelve_returns_the_default
    IntegrationTestHelpers.with_env({ 'QUONFIG_ITD_GETTER_INT' => 'twelve' }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_int('getter.contract.provided.int.malformed', default: 7)
      assert_equal 7, actual, 'client.get_int(getter.contract.provided.int.malformed, default: 7)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # INT getter on env-var-provided malformed int "twelve" with no default returns nil
  def test_int_getter_on_env_var_provided_malformed_int_twelve_with_no_default_returns_nil
    IntegrationTestHelpers.with_env({ 'QUONFIG_ITD_GETTER_INT' => 'twelve' }) do
      client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
      actual = client.get_int('getter.contract.provided.int.malformed')
      assert_nil actual, 'client.get_int(getter.contract.provided.int.malformed)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # DOUBLE getter on env-var-provided malformed double "abc" returns the default
  def test_double_getter_on_env_var_provided_malformed_double_abc_returns_the_default
    IntegrationTestHelpers.with_env({ 'QUONFIG_ITD_GETTER_DOUBLE' => 'abc' }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_float('getter.contract.provided.double.malformed', default: 7.5)
      assert_equal 7.5, actual, 'client.get_float(getter.contract.provided.double.malformed, default: 7.5)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # DOUBLE getter on env-var-provided malformed double "abc" with no default returns nil
  def test_double_getter_on_env_var_provided_malformed_double_abc_with_no_default_returns_nil
    IntegrationTestHelpers.with_env({ 'QUONFIG_ITD_GETTER_DOUBLE' => 'abc' }) do
      client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
      actual = client.get_float('getter.contract.provided.double.malformed')
      assert_nil actual, 'client.get_float(getter.contract.provided.double.malformed)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # STRING getter on a missing env var returns the default
  def test_string_getter_on_a_missing_env_var_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('provided.by.missing.env.var', default: 'DEFAULT')
    assert_equal 'DEFAULT', actual, 'client.get_string(provided.by.missing.env.var, default: DEFAULT)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING getter on a missing env var with no default returns nil
  def test_string_getter_on_a_missing_env_var_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_string('provided.by.missing.env.var')
    assert_nil actual, 'client.get_string(provided.by.missing.env.var)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # STRING getter on a decryption failure returns the default
  def test_string_getter_on_a_decryption_failure_returns_the_default
    IntegrationTestHelpers.with_env({ 'QUONFIG_KEYSET' => qf1_test_keyset('QUONFIG_KEYSET/1'), 'QUONFIG_KEYSETX' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST_PROD' => qf1_test_keyset('QUONFIG_KEYSET_TEST_PROD/new', 'QUONFIG_KEYSET_TEST_PROD/old') }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_string('qf1.secret.key.not.held', default: 'DEFAULT')
      assert_equal 'DEFAULT', actual, 'client.get_string(qf1.secret.key.not.held, default: DEFAULT)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # STRING getter on a decryption failure with no default returns nil
  def test_string_getter_on_a_decryption_failure_with_no_default_returns_nil
    IntegrationTestHelpers.with_env({ 'QUONFIG_KEYSET' => qf1_test_keyset('QUONFIG_KEYSET/1'), 'QUONFIG_KEYSETX' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST' => qf1_test_keyset('QUONFIG_KEYSET_TEST/1'), 'QUONFIG_KEYSET_TEST_PROD' => qf1_test_keyset('QUONFIG_KEYSET_TEST_PROD/new', 'QUONFIG_KEYSET_TEST_PROD/old') }) do
      client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
      actual = client.get_string('qf1.secret.key.not.held')
      assert_nil actual, 'client.get_string(qf1.secret.key.not.held)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end

  # BOOLEAN getter on a missing bool env var returns the default
  def test_boolean_getter_on_a_missing_bool_env_var_returns_the_default
    client = IntegrationTestHelpers.build_client
    actual = client.get_bool('getter.contract.provided.bool.missing', default: true)
    assert_equal true, actual, 'client.get_bool(getter.contract.provided.bool.missing, default: true)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # BOOLEAN getter on a missing bool env var with no default returns nil
  def test_boolean_getter_on_a_missing_bool_env_var_with_no_default_returns_nil
    client = IntegrationTestHelpers.build_client(on_no_default: :return_nil)
    actual = client.get_bool('getter.contract.provided.bool.missing')
    assert_nil actual, 'client.get_bool(getter.contract.provided.bool.missing)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # BOOLEAN getter on env-var-provided bool "false" returns false
  def test_boolean_getter_on_env_var_provided_bool_false_returns_false
    IntegrationTestHelpers.with_env({ 'QUONFIG_ITD_GETTER_BOOL' => 'false' }) do
      client = IntegrationTestHelpers.build_client
      actual = client.get_bool('getter.contract.provided.bool')
      assert_equal false, actual, 'client.get_bool(getter.contract.provided.bool)'
      IntegrationTestHelpers.acknowledge_expected_warnings
    end
  end
end
