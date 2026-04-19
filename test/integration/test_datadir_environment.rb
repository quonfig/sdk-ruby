# frozen_string_literal: true
#
# AUTO-GENERATED from integration-test-data/tests/eval/datadir_environment.yaml.
# Regenerate with `bundle exec ruby scripts/generate_integration_tests.rb`.
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestDatadirEnvironment < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store("datadir_environment")
  end

  # datadir with environment option gets environment-specific value
  def test_datadir_with_environment_option_gets_environment_specific_value
    skip("datadir-mode Quonfig::Client.new(datadir:) integration not yet wired (qfg-dk6.x)")
  end

  # datadir with QUONFIG_ENVIRONMENT env var gets environment-specific value
  def test_datadir_with_quonfig_environment_env_var_gets_environment_specific_value
    skip("datadir-mode Quonfig::Client.new(datadir:) integration not yet wired (qfg-dk6.x)")
  end

  # environment option supersedes QUONFIG_ENVIRONMENT env var
  def test_environment_option_supersedes_quonfig_environment_env_var
    skip("datadir-mode Quonfig::Client.new(datadir:) integration not yet wired (qfg-dk6.x)")
  end

  # config without environment override returns default value
  def test_config_without_environment_override_returns_default_value
    skip("datadir-mode Quonfig::Client.new(datadir:) integration not yet wired (qfg-dk6.x)")
  end

  # datadir without environment fails to init
  def test_datadir_without_environment_fails_to_init
    skip("datadir-mode Quonfig::Client.new(datadir:) integration not yet wired (qfg-dk6.x)")
  end

  # datadir with invalid environment fails to init
  def test_datadir_with_invalid_environment_fails_to_init
    skip("datadir-mode Quonfig::Client.new(datadir:) integration not yet wired (qfg-dk6.x)")
  end
end
