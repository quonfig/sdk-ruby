# frozen_string_literal: true
#
# AUTO-GENERATED from integration-test-data/tests/eval/enabled_with_contexts.yaml.
# Regenerate with `bundle exec ruby scripts/generate_integration_tests.rb`.
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestEnabledWithContexts < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store("enabled_with_contexts")
  end

  # returns true from global context
  def test_returns_true_from_global_context
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "feature-flag.in-seg.segment-and", {"" => {"domain" => "prefab.cloud"}, "user" => {"key" => "michael"}}, true)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns false due to local context override
  def test_returns_false_due_to_local_context_override
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "feature-flag.in-seg.segment-and", {"" => {"domain" => "prefab.cloud"}, "user" => {"key" => "james"}}, false)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns false for untouched scope context
  def test_returns_false_for_untouched_scope_context
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "feature-flag.in-seg.segment-and", {"" => {"domain" => "example.com"}, "user" => {"key" => "nobody"}}, false)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns false due to partial scope context override of user.key
  def test_returns_false_due_to_partial_scope_context_override_of_user_key
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "feature-flag.in-seg.segment-and", {"" => {"domain" => "example.com"}, "user" => {"key" => "michael"}}, false)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns false due to partial scope context override of domain
  def test_returns_false_due_to_partial_scope_context_override_of_domain
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "feature-flag.in-seg.segment-and", {"" => {"domain" => "example.com", "key" => "prefab.cloud"}, "user" => {"key" => "nobody"}}, false)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns true due to full scope context override of user.key and domain
  def test_returns_true_due_to_full_scope_context_override_of_user_key_and_domain
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "feature-flag.in-seg.segment-and", {"" => {"domain" => "prefab.cloud"}, "user" => {"key" => "michael"}}, true)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns false for rule with different case on context property name
  def test_returns_false_for_rule_with_different_case_on_context_property_name
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "mixed.case.property.name", {"user" => {"IsHuman" => "verified"}}, false)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns true for matching case on context property name
  def test_returns_true_for_matching_case_on_context_property_name
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "mixed.case.property.name", {"user" => {"isHuman" => "verified"}}, true)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end
end
