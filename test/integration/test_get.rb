# frozen_string_literal: true
#
# AUTO-GENERATED from integration-test-data/tests/eval/get.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestGet < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store("get")
  end

  # get returns a found value for key
  def test_get_returns_a_found_value_for_key
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "my-test-key", {}, "my-test-value")
  end

  # get returns nil if value not found
  def test_get_returns_nil_if_value_not_found
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "my-missing-key", {}, nil)
  end

  # get returns a default for a missing value if a default is given
  def test_get_returns_a_default_for_a_missing_value_if_a_default_is_given
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "my-missing-key", {}, "DEFAULT")
  end

  # get ignores a provided default if the key is found
  def test_get_ignores_a_provided_default_if_the_key_is_found
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "my-test-key", {}, "my-test-value")
  end

  # get can return a double
  def test_get_can_return_a_double
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "my-double-key", {}, 9.95)
  end

  # get can return a string list
  def test_get_can_return_a_string_list
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "my-string-list-key", {}, ["a", "b", "c"])
  end

  # can return an override based on the default context
  def test_can_return_an_override_based_on_the_default_context
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "my-overridden-key", {}, "overridden")
  end

  # can return a value provided by an environment variable
  def test_can_return_a_value_provided_by_an_environment_variable
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "prefab.secrets.encryption.key", {}, "c87ba22d8662282abe8a0e4651327b579cb64a454ab0f4c170b45b15f049a221")
  end

  # can return a value provided by an environment variable after type coercion
  def test_can_return_a_value_provided_by_an_environment_variable_after_type_coercion
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "provided.a.number", {}, 1234)
  end

  # can decrypt and return a secret value (with decryption key in in env var)
  def test_can_decrypt_and_return_a_secret_value_with_decryption_key_in_in_env_var
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "a.secret.config", {}, "hello.world")
  end

  # duration 200 ms
  def test_duration_200_ms
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "test.duration.PT0.2S", {}, 200)
  end

  # duration 90S
  def test_duration_90s
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "test.duration.PT90S", {}, 90000)
  end

  # duration 1.5M
  def test_duration_1_5m
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "test.duration.PT1.5M", {}, 90000)
  end

  # duration 0.5H
  def test_duration_0_5h
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "test.duration.PT0.5H", {}, 1800000)
  end

  # duration test.duration.P1DT6H2M1.5S
  def test_duration_test_duration_p1dt6h2m1_5s
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "test.duration.P1DT6H2M1.5S", {}, 108121500)
  end

  # json test
  def test_json_test
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "test.json", {}, {"a" => 1, "b" => "c"})
  end

  # get returns a native json object (not a stringified payload)
  def test_get_returns_a_native_json_object_not_a_stringified_payload
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "test.json", {}, {"a" => 1, "b" => "c"})
  end

  # list on left side test (1)
  def test_list_on_left_side_test_1
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "left.hand.list.test", {"user" => {"name" => "james", "aka" => ["happy", "sleepy"]}}, "correct")
  end

  # list on left side test (2)
  def test_list_on_left_side_test_2
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "left.hand.list.test", {"user" => {"name" => "james", "aka" => ["a", "b"]}}, "default")
  end

  # list on left side test opposite (1)
  def test_list_on_left_side_test_opposite_1
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "left.hand.test.opposite", {"user" => {"name" => "james", "aka" => ["happy", "sleepy"]}}, "default")
  end

  # list on left side test (3)
  def test_list_on_left_side_test_3
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "left.hand.test.opposite", {"user" => {"name" => "james", "aka" => ["a", "b"]}}, "correct")
  end
end
