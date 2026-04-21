# frozen_string_literal: true

require 'test_helper'

class TestContext < Minitest::Test
  EXAMPLE_PROPERTIES = {
    user: { key: 'some-user-key', name: 'Ted' },
    team: { key: 'abc', plan: 'pro' }
  }.freeze

  def test_initialize_with_empty_context
    context = Quonfig::Context.new({})
    assert_empty context.contexts
    assert context.blank?
  end

  def test_initialize_with_hash
    context = Quonfig::Context.new(test: { foo: 'bar' })
    assert_equal 1, context.contexts.size
    assert_equal 'bar', context.get('test.foo')
  end

  def test_initialize_with_multiple_hashes
    context = Quonfig::Context.new(test: { foo: 'bar' }, other: { foo: 'baz' })
    assert_equal 2, context.contexts.size
    assert_equal 'bar', context.get('test.foo')
    assert_equal 'baz', context.get('other.foo')
  end

  def test_initialize_with_invalid_argument
    assert_raises(ArgumentError) { Quonfig::Context.new([]) }
  end

  def test_setting
    context = Quonfig::Context.new({})
    context.set('user', { key: 'value' })
    context.set(:other, { key: 'different', something: 'other' })

    assert_equal(
      stringify(user: { key: 'value' }, other: { key: 'different', something: 'other' }),
      context.to_h
    )
  end

  def test_getting
    context = Quonfig::Context.new(EXAMPLE_PROPERTIES)
    assert_equal('some-user-key', context.get('user.key'))
    assert_equal('pro', context.get('team.plan'))
  end

  def test_dot_notation_getting
    context = Quonfig::Context.new('user' => { 'key' => 'value' })
    assert_equal('value', context.get('user.key'))
  end

  def test_dot_notation_getting_with_symbols
    context = Quonfig::Context.new(user: { key: 'value' })
    assert_equal('value', context.get('user.key'))
  end

  def test_get_returns_nil_for_missing_property
    context = Quonfig::Context.new(user: { key: 'value' })
    assert_nil context.get('user.missing')
    assert_nil context.get('absent.key')
  end

  def test_clear
    context = Quonfig::Context.new(EXAMPLE_PROPERTIES)
    context.clear

    assert_empty context.to_h
    assert context.blank?
  end

  def test_to_h_stringifies_keys
    context = Quonfig::Context.new(EXAMPLE_PROPERTIES)
    assert_equal stringify(EXAMPLE_PROPERTIES), context.to_h
  end

  def test_legacy_flat_hash_shorthand_promotes_to_blank_named_context
    # Pre-named-contexts callers passed a flat Hash. The constructor still
    # accepts that shape and stuffs it under the empty-string named context.
    context = Quonfig::Context.new('foo' => 'bar')
    assert_equal 'bar', context.get('.foo')
  end

  def test_grouped_key_combines_named_contexts_by_key
    context = Quonfig::Context.new(
      user: { key: 'u1' },
      team: { key: 't1' }
    )

    assert_equal 'team:t1|user:u1', context.grouped_key
  end

  def test_named_context_lookup_returns_namedcontext
    context = Quonfig::Context.new(user: { key: 'u1', name: 'Ted' })
    user = context.context('user')

    assert_kind_of Quonfig::Context::NamedContext, user
    assert_equal 'user', user.name
    assert_equal({ 'key' => 'u1', 'name' => 'Ted' }, user.to_h)
  end

  def test_named_context_lookup_for_missing_returns_empty_namedcontext
    context = Quonfig::Context.new(user: { key: 'u1' })
    missing = context.context('absent')

    assert_kind_of Quonfig::Context::NamedContext, missing
    assert_equal 'absent', missing.name
    assert_empty missing.to_h
  end

  def test_comparable
    a = Quonfig::Context.new(user: { key: 'u1' })
    b = Quonfig::Context.new(user: { key: 'u1' })
    c = Quonfig::Context.new(user: { key: 'u2' })

    assert_equal a, b
    refute_equal a, c
  end

  private

  def stringify(hash)
    hash.map { |k, v| [k.to_s, stringify_keys(v)] }.to_h
  end

  def stringify_keys(value)
    if value.is_a?(Hash)
      value.transform_keys(&:to_s)
    else
      value
    end
  end
end
