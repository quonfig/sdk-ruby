# frozen_string_literal: true
#
# AUTO-GENERATED from integration-test-data/tests/eval/datadir_environment.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestDatadirEnvironment < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store("datadir_environment")
  end

  # datadir with environment option gets environment-specific value
  def test_datadir_with_environment_option_gets_environment_specific_value
    client = Quonfig::Client.new(datadir: IntegrationTestHelpers.data_dir, environment: "Production")
    assert_equal "test4", client.get("james.test.key")
  end

  # datadir with QUONFIG_ENVIRONMENT env var gets environment-specific value
  def test_datadir_with_quonfig_environment_env_var_gets_environment_specific_value
    IntegrationTestHelpers.with_env({"QUONFIG_ENVIRONMENT" => "Production"}) do
      client = Quonfig::Client.new(datadir: IntegrationTestHelpers.data_dir)
      assert_equal "test4", client.get("james.test.key")
    end
  end

  # environment option supersedes QUONFIG_ENVIRONMENT env var
  def test_environment_option_supersedes_quonfig_environment_env_var
    IntegrationTestHelpers.with_env({"QUONFIG_ENVIRONMENT" => "nonexistent"}) do
      client = Quonfig::Client.new(datadir: IntegrationTestHelpers.data_dir, environment: "Production")
      assert_equal "test4", client.get("james.test.key")
    end
  end

  # config without environment override returns default value
  def test_config_without_environment_override_returns_default_value
    client = Quonfig::Client.new(datadir: IntegrationTestHelpers.data_dir, environment: "Production")
    assert_equal "hello from no env row", client.get("config.with.only.default.env.row")
  end

  # datadir without environment fails to init
  def test_datadir_without_environment_fails_to_init
    assert_raises(Quonfig::Errors::MissingEnvironmentError) { Quonfig::Client.new(datadir: IntegrationTestHelpers.data_dir) }
  end

  # datadir with invalid environment fails to init
  def test_datadir_with_invalid_environment_fails_to_init
    assert_raises(Quonfig::Errors::InvalidEnvironmentError) { Quonfig::Client.new(datadir: IntegrationTestHelpers.data_dir, environment: "nonexistent") }
  end
end
