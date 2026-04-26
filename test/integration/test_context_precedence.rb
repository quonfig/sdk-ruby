# frozen_string_literal: true
#
# AUTO-GENERATED from integration-test-data/tests/eval/context_precedence.yaml.
# Regenerate with:
#   cd integration-test-data/generators && npm run generate -- --target=ruby
# Source: integration-test-data/generators/src/targets/ruby.ts
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestContextPrecedence < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store("context_precedence")
  end

  # returns the correct `flag` value using the global context (1)
  def test_returns_the_correct_flag_value_using_the_global_context_1
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "mixed.case.property.name", {"user" => {"isHuman" => "verified"}}, true)
  end

  # returns the correct `flag` value using the global context (2)
  def test_returns_the_correct_flag_value_using_the_global_context_2
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "mixed.case.property.name", {"user" => {"isHuman" => "?"}}, false)
  end

  # returns the correct `flag` value when local context clobbers global context (1)
  def test_returns_the_correct_flag_value_when_local_context_clobbers_global_context_1
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "mixed.case.property.name", {"user" => {"isHuman" => "verified"}}, true)
  end

  # returns the correct `flag` value when local context clobbers global context (2)
  def test_returns_the_correct_flag_value_when_local_context_clobbers_global_context_2
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "mixed.case.property.name", {"user" => {"isHuman" => "?"}}, false)
  end

  # returns the correct `flag` value when block context clobbers global context (1)
  def test_returns_the_correct_flag_value_when_block_context_clobbers_global_context_1
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "mixed.case.property.name", {"user" => {"isHuman" => "?"}}, false)
  end

  # returns the correct `flag` value when block context clobbers global context (2)
  def test_returns_the_correct_flag_value_when_block_context_clobbers_global_context_2
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "mixed.case.property.name", {"user" => {"isHuman" => "verified"}}, true)
  end

  # returns the correct `flag` value when local context clobbers block context (1)
  def test_returns_the_correct_flag_value_when_local_context_clobbers_block_context_1
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "mixed.case.property.name", {"user" => {"isHuman" => "?"}}, false)
  end

  # returns the correct `flag` value when local context clobbers block context (2)
  def test_returns_the_correct_flag_value_when_local_context_clobbers_block_context_2
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_enabled(resolver, "mixed.case.property.name", {"user" => {"isHuman" => "verified"}}, true)
  end

  # returns the correct `get` value using the global context (1)
  def test_returns_the_correct_get_value_using_the_global_context_1
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "basic.rule.config", {"user" => {"email" => "test@prefab.cloud"}}, "override")
  end

  # returns the correct `get` value using the global context (2)
  def test_returns_the_correct_get_value_using_the_global_context_2
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "basic.rule.config", {"user" => {"email" => "test@example.com"}}, "default")
  end

  # returns the correct `get` value when local context clobbers global context (1)
  def test_returns_the_correct_get_value_when_local_context_clobbers_global_context_1
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "basic.rule.config", {"user" => {"email" => "test@prefab.cloud"}}, "override")
  end

  # returns the correct `get` value when local context clobbers global context (2)
  def test_returns_the_correct_get_value_when_local_context_clobbers_global_context_2
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "basic.rule.config", {"user" => {"email" => "test@example.com"}}, "default")
  end

  # returns the correct `get` value when block context clobbers global context (1)
  def test_returns_the_correct_get_value_when_block_context_clobbers_global_context_1
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "basic.rule.config", {"user" => {"email" => "test@example.com"}}, "default")
  end

  # returns the correct `get` value when block context clobbers global context (2)
  def test_returns_the_correct_get_value_when_block_context_clobbers_global_context_2
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "basic.rule.config", {"user" => {"email" => "test@prefab.cloud"}}, "override")
  end

  # returns the correct `get` value when local context clobbers block context (1)
  def test_returns_the_correct_get_value_when_local_context_clobbers_block_context_1
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "basic.rule.config", {"user" => {"email" => "test@example.com"}}, "default")
  end

  # returns the correct `get` value when local context clobbers block context (2)
  def test_returns_the_correct_get_value_when_local_context_clobbers_block_context_2
    resolver = IntegrationTestHelpers.build_resolver(@store)
    IntegrationTestHelpers.assert_resolved(resolver, "basic.rule.config", {"user" => {"email" => "test@prefab.cloud"}}, "override")
  end
end
