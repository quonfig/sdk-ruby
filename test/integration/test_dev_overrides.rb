# frozen_string_literal: true
#
# AUTO-GENERATED from integration-test-data/tests/eval/dev_overrides.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestDevOverrides < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store("dev_overrides")
  end

  # override fires when quonfig-user.email matches
  def test_override_fires_when_quonfig_user_email_matches
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.dev-override", {"quonfig-user" => {"email" => "bob@foo.com"}}, true)
  end

  # override does not fire when attribute absent (prod simulation)
  def test_override_does_not_fire_when_attribute_absent_prod_simulation
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.dev-override", {"user" => {"email" => "bob@foo.com"}}, false)
  end

  # override matches any email in IS_ONE_OF list
  def test_override_matches_any_email_in_is_one_of_list
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.dev-override.multi-email", {"quonfig-user" => {"email" => "alice@foo.com"}}, true)
  end

  # override beats customer rule by priority
  def test_override_beats_customer_rule_by_priority
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "feature-flag.dev-override.priority", {"quonfig-user" => {"email" => "bob@foo.com"}, "user" => {"country" => "DE"}}, true)
  end
end
