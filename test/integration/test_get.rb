# frozen_string_literal: true

# AUTO-GENERATED from integration-test-data/tests/eval/get.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestGet < Minitest::Test
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
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('prefab.secrets.encryption.key')
    assert_equal 'c87ba22d8662282abe8a0e4651327b579cb64a454ab0f4c170b45b15f049a221', actual, 'client.get_string(prefab.secrets.encryption.key)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # can return a value provided by an environment variable after type coercion
  def test_can_return_a_value_provided_by_an_environment_variable_after_type_coercion
    client = IntegrationTestHelpers.build_client
    actual = client.get_int('provided.a.number')
    assert_equal 1234, actual, 'client.get_int(provided.a.number)'
    IntegrationTestHelpers.acknowledge_expected_warnings
  end

  # can decrypt and return a secret value (with decryption key in in env var)
  def test_can_decrypt_and_return_a_secret_value_with_decryption_key_in_in_env_var
    client = IntegrationTestHelpers.build_client
    actual = client.get_string('a.secret.config')
    assert_equal 'hello.world', actual, 'client.get_string(a.secret.config)'
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
end
