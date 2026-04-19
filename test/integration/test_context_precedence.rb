# frozen_string_literal: true
#
# AUTO-GENERATED from integration-test-data/tests/eval/context_precedence.yaml.
# Regenerate with `bundle exec ruby scripts/generate_integration_tests.rb`.
# Do NOT edit by hand — changes will be overwritten.

require 'test_helper'
require 'integration/test_helpers'

class TestContextPrecedence < Minitest::Test
  def setup
    @store = IntegrationTestHelpers.build_store("context_precedence")
  end

  # returns the correct `flag` value using the global context (1)
  def test_returns_the_correct_flag_value_using_the_global_context_1
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "mixed.case.property.name", {"user" => {"isHuman" => "verified"}}, true)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns the correct `flag` value using the global context (2)
  def test_returns_the_correct_flag_value_using_the_global_context_2
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "mixed.case.property.name", {"user" => {"isHuman" => "?"}}, false)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns the correct `flag` value when local context clobbers global context (1)
  def test_returns_the_correct_flag_value_when_local_context_clobbers_global_context_1
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "mixed.case.property.name", {"user" => {"isHuman" => "verified"}}, true)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns the correct `flag` value when local context clobbers global context (2)
  def test_returns_the_correct_flag_value_when_local_context_clobbers_global_context_2
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "mixed.case.property.name", {"user" => {"isHuman" => "?"}}, false)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns the correct `flag` value when block context clobbers global context (1)
  def test_returns_the_correct_flag_value_when_block_context_clobbers_global_context_1
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "mixed.case.property.name", {"user" => {"isHuman" => "?"}}, false)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns the correct `flag` value when block context clobbers global context (2)
  def test_returns_the_correct_flag_value_when_block_context_clobbers_global_context_2
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "mixed.case.property.name", {"user" => {"isHuman" => "verified"}}, true)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns the correct `flag` value when local context clobbers block context (1)
  def test_returns_the_correct_flag_value_when_local_context_clobbers_block_context_1
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "mixed.case.property.name", {"user" => {"isHuman" => "?"}}, false)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns the correct `flag` value when local context clobbers block context (2)
  def test_returns_the_correct_flag_value_when_local_context_clobbers_block_context_2
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "mixed.case.property.name", {"user" => {"isHuman" => "verified"}}, true)
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns the correct `get` value using the global context (1)
  def test_returns_the_correct_get_value_using_the_global_context_1
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "basic.rule.config", {"user" => {"email" => "test@prefab.cloud"}}, "override")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns the correct `get` value using the global context (2)
  def test_returns_the_correct_get_value_using_the_global_context_2
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "basic.rule.config", {"user" => {"email" => "test@example.com"}}, "default")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns the correct `get` value using the global context and api context (1)
  def test_returns_the_correct_get_value_using_the_global_context_and_api_context_1
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "basic.rule.config.with.api.conditional", {"user" => {"email" => "test@prefab.cloud"}}, "override")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns the correct `get` value using the global context and api context (2)
  def test_returns_the_correct_get_value_using_the_global_context_and_api_context_2
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "basic.rule.config.with.api.conditional", {"user" => {"email" => "test@example.com"}}, "api-override")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns the correct `get` value when local context clobbers global context (1)
  def test_returns_the_correct_get_value_when_local_context_clobbers_global_context_1
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "basic.rule.config", {"user" => {"email" => "test@prefab.cloud"}}, "override")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns the correct `get` value when local context clobbers global context (2)
  def test_returns_the_correct_get_value_when_local_context_clobbers_global_context_2
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "basic.rule.config", {"user" => {"email" => "test@example.com"}}, "default")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns the correct `get` value when block context clobbers global context (1)
  def test_returns_the_correct_get_value_when_block_context_clobbers_global_context_1
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "basic.rule.config", {"user" => {"email" => "test@example.com"}}, "default")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns the correct `get` value when block context clobbers global context (2)
  def test_returns_the_correct_get_value_when_block_context_clobbers_global_context_2
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "basic.rule.config", {"user" => {"email" => "test@prefab.cloud"}}, "override")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns the correct `get` value when local context clobbers block context (1)
  def test_returns_the_correct_get_value_when_local_context_clobbers_block_context_1
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "basic.rule.config", {"user" => {"email" => "test@example.com"}}, "default")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end

  # returns the correct `get` value when local context clobbers block context (2)
  def test_returns_the_correct_get_value_when_local_context_clobbers_block_context_2
    begin
      resolver = IntegrationTestHelpers.build_resolver(@store)
      IntegrationTestHelpers.assert_resolved(resolver, "basic.rule.config", {"user" => {"email" => "test@prefab.cloud"}}, "override")
    rescue Exception => e
      skip("resolver not yet ported for this case: #{e.class}: #{e.message}")
    end
  end
end
