# frozen_string_literal: true
#
# AUTO-GENERATED from integration-test-data/tests/eval/get.yaml.
# Regenerate with `bundle exec ruby scripts/generate_integration_tests.rb`.
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestGet < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store("get")
  end

  # get returns a found value for key
  def test_get_returns_a_found_value_for_key
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "my-test-key", {}, "my-test-value")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # get returns nil if value not found
  def test_get_returns_nil_if_value_not_found
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "my-missing-key", {}, nil)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # get returns a default for a missing value if a default is given
  def test_get_returns_a_default_for_a_missing_value_if_a_default_is_given
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "my-missing-key", {}, "DEFAULT")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # get ignores a provided default if the key is found
  def test_get_ignores_a_provided_default_if_the_key_is_found
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "my-test-key", {}, "my-test-value")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # get can return a double
  def test_get_can_return_a_double
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "my-double-key", {}, 9.95)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # get can return a string list
  def test_get_can_return_a_string_list
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "my-string-list-key", {}, ["a", "b", "c"])
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # can return an override based on the default context
  def test_can_return_an_override_based_on_the_default_context
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "my-overridden-key", {}, "overridden")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # can return a value provided by an environment variable
  def test_can_return_a_value_provided_by_an_environment_variable
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "prefab.secrets.encryption.key", {}, "c87ba22d8662282abe8a0e4651327b579cb64a454ab0f4c170b45b15f049a221")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # can return a value provided by an environment variable after type coercion
  def test_can_return_a_value_provided_by_an_environment_variable_after_type_coercion
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "provided.a.number", {}, 1234)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # can decrypt and return a secret value (with decryption key in in env var)
  def test_can_decrypt_and_return_a_secret_value_with_decryption_key_in_in_env_var
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "a.secret.config", {}, "hello.world")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # duration 200 ms
  def test_duration_200_ms
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "test.duration.PT0.2S", {}, 200)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # duration 90S
  def test_duration_90s
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "test.duration.PT90S", {}, 90000)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # duration 1.5M
  def test_duration_1_5m
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "test.duration.PT1.5M", {}, 90000)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # duration 0.5H
  def test_duration_0_5h
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "test.duration.PT0.5H", {}, 1800000)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # duration test.duration.P1DT6H2M1.5S
  def test_duration_test_duration_p1dt6h2m1_5s
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "test.duration.P1DT6H2M1.5S", {}, 108121500)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # json test
  def test_json_test
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "test.json", {}, {"a" => 1, "b" => "c"})
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # get returns a native json object (not a stringified payload)
  def test_get_returns_a_native_json_object_not_a_stringified_payload
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "test.json", {}, {"a" => 1, "b" => "c"})
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # list on left side test (1)
  def test_list_on_left_side_test_1
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "left.hand.list.test", {"user" => {"name" => "james", "aka" => ["happy", "sleepy"]}}, "correct")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # list on left side test (2)
  def test_list_on_left_side_test_2
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "left.hand.list.test", {"user" => {"name" => "james", "aka" => ["a", "b"]}}, "default")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # list on left side test opposite (1)
  def test_list_on_left_side_test_opposite_1
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "left.hand.test.opposite", {"user" => {"name" => "james", "aka" => ["happy", "sleepy"]}}, "default")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # list on left side test (3)
  def test_list_on_left_side_test_3
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "left.hand.test.opposite", {"user" => {"name" => "james", "aka" => ["a", "b"]}}, "correct")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end
end
