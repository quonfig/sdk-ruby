# frozen_string_literal: true

require 'test_helper'

# BoundClient is a pure delegation wrapper: it forwards typed-getter calls to
# the underlying client with its bound context. These tests exercise that
# wrapper with a tiny FakeClient double so they do not depend on the rest of
# the eval pipeline (which is mid-JSON-migration and not fully green yet).
class TestBoundClient < Minitest::Test
  # Minimal stand-in for Quonfig::Client that records the context each typed
  # getter was called with. BoundClient only exercises the public typed-getter
  # surface + enabled?, so that's all we need here.
  class FakeClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def get_string(key, default: Quonfig::NO_DEFAULT_PROVIDED, context: Quonfig::NO_DEFAULT_PROVIDED)
      @calls << [:get_string, key, default, context]
      context
    end

    def get_int(key, default: Quonfig::NO_DEFAULT_PROVIDED, context: Quonfig::NO_DEFAULT_PROVIDED)
      @calls << [:get_int, key, default, context]
      context
    end

    def enabled?(feature_name, jit_context = Quonfig::NO_DEFAULT_PROVIDED)
      @calls << [:enabled?, feature_name, jit_context]
      jit_context
    end
  end

  def test_get_string_uses_bound_context
    fake = FakeClient.new
    bound = Quonfig::BoundClient.new(fake, user: { 'key' => '99' })

    bound.get_string('my.str')

    call = fake.calls.last
    assert_equal :get_string,                 call[0]
    assert_equal 'my.str',                    call[1]
    assert_equal Quonfig::NO_DEFAULT_PROVIDED, call[2]
    assert_equal({ user: { 'key' => '99' } }, call[3])
  end

  def test_enabled_uses_bound_context
    fake = FakeClient.new
    bound = Quonfig::BoundClient.new(fake, user: { 'key' => '99' })

    bound.enabled?('my.flag')

    call = fake.calls.last
    assert_equal :enabled?,                   call[0]
    assert_equal 'my.flag',                   call[1]
    assert_equal({ user: { 'key' => '99' } }, call[2])
  end

  def test_in_context_returns_new_bound_with_merged_context
    fake = FakeClient.new
    bound = Quonfig::BoundClient.new(fake, user: { 'key' => '99' })

    chained = bound.in_context(org: { 'id' => 'acme' })

    assert_kind_of Quonfig::BoundClient, chained
    refute_same bound, chained,
                'in_context should return a NEW BoundClient, not self'

    expected = { user: { 'key' => '99' }, org: { 'id' => 'acme' } }
    assert_equal expected, chained.context
  end

  def test_in_context_merged_context_is_used_on_typed_getter
    fake = FakeClient.new
    bound = Quonfig::BoundClient.new(fake, user: { 'key' => '99' })
    chained = bound.in_context(org: { 'id' => 'acme' })

    chained.get_string('my.str')

    ctx_arg = fake.calls.last[3]
    assert_equal({ user: { 'key' => '99' }, org: { 'id' => 'acme' } }, ctx_arg)
  end

  def test_in_context_later_keys_within_same_named_ctx_override_earlier
    fake = FakeClient.new
    bound = Quonfig::BoundClient.new(fake, user: { 'key' => '99', 'plan' => 'free' })

    chained = bound.in_context(user: { 'plan' => 'pro' })

    # 'plan' overridden; 'key' preserved from parent bound
    assert_equal({ user: { 'key' => '99', 'plan' => 'pro' } }, chained.context)
  end

  def test_in_context_does_not_mutate_parent_bound_context
    fake = FakeClient.new
    bound = Quonfig::BoundClient.new(fake, user: { 'key' => '99' })

    bound.in_context(org: { 'id' => 'acme' })

    assert_equal({ user: { 'key' => '99' } }, bound.context)
  end

  def test_bound_client_is_frozen
    bound = Quonfig::BoundClient.new(FakeClient.new, user: { 'key' => '99' })
    assert_predicate bound, :frozen?
  end
end
