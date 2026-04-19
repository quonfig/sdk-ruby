# frozen_string_literal: true

require 'test_helper'

class TestContext < Minitest::Test
  EXAMPLE_PROPERTIES = { user: { key: 'some-user-key', name: 'Ted' }, team: { key: 'abc', plan: 'pro' } }.freeze

  def setup
    super
    Quonfig::Context.current = nil
  end

  def test_initialize_with_empty_context
    context = Quonfig::Context.new({})
    assert_empty context.contexts
  end

  def test_initialize_with_hash
    context = Quonfig::Context.new(test: { foo: 'bar' })
    assert_equal 1, context.contexts.size
    assert_equal 'bar', context.get("test.foo")
  end

  def test_initialize_with_multiple_hashes
    context = Quonfig::Context.new(test: { foo: 'bar' }, other: { foo: 'baz' })
    assert_equal 2, context.contexts.size
    assert_equal 'bar', context.get("test.foo")
    assert_equal 'baz', context.get("other.foo")
  end

  def test_initialize_with_invalid_argument
    assert_raises(ArgumentError) { Quonfig::Context.new([]) }
  end

  def test_current
    context = Quonfig::Context.current
    assert_instance_of Quonfig::Context, context
    assert_empty context.to_h
  end

  def test_current_set
    context = Quonfig::Context.new(EXAMPLE_PROPERTIES)
    Quonfig::Context.current = context.to_h
    assert_instance_of Quonfig::Context, context
    assert_equal stringify(EXAMPLE_PROPERTIES), context.to_h
  end

  def test_with_context
    Quonfig::Context.with_context(EXAMPLE_PROPERTIES) do
      context = Quonfig::Context.current
      assert_equal(stringify(EXAMPLE_PROPERTIES), context.to_h)
      assert_equal('some-user-key', context.get('user.key'))
    end
  end

  def test_with_context_nesting
    Quonfig::Context.with_context(EXAMPLE_PROPERTIES) do
      Quonfig::Context.with_context({ user: { key: 'abc', other: 'different' } }) do
        context = Quonfig::Context.current
        assert_equal({ 'user' => { 'key' => 'abc', 'other' => 'different' } }, context.to_h)
      end

      context = Quonfig::Context.current
      assert_equal(stringify(EXAMPLE_PROPERTIES), context.to_h)
    end
  end

  def test_with_context_merge_nesting
    Quonfig::Context.with_context(EXAMPLE_PROPERTIES) do
      Quonfig::Context.with_merged_context({ user: { key: 'hij', other: 'different' } }) do
        context = Quonfig::Context.current
        assert_nil context.get('user.name')
        assert_equal context.get('user.key'), 'hij'
        assert_equal context.get('user.other'), 'different'

        assert_equal context.get('team.key'), 'abc'
        assert_equal context.get('team.plan'), 'pro'
      end

      context = Quonfig::Context.current
      assert_equal(stringify(EXAMPLE_PROPERTIES), context.to_h)
    end
  end

  def test_setting
    context = Quonfig::Context.new({})
    context.set('user', { key: 'value' })
    context.set(:other, { key: 'different', something: 'other' })
    assert_equal(stringify({ user: { key: 'value' }, other: { key: 'different', something: 'other' } }), context.to_h)
  end

  def test_getting
    context = Quonfig::Context.new(EXAMPLE_PROPERTIES)
    assert_equal('some-user-key', context.get('user.key'))
    assert_equal('pro', context.get('team.plan'))
  end

  def test_dot_notation_getting
    context = Quonfig::Context.new({ 'user' => { 'key' => 'value' } })
    assert_equal('value', context.get('user.key'))
  end

  def test_dot_notation_getting_with_symbols
    context = Quonfig::Context.new({ user: { key: 'value' } })
    assert_equal('value', context.get('user.key'))
  end

  def test_clear
    context = Quonfig::Context.new(EXAMPLE_PROPERTIES)
    context.clear

    assert_empty context.to_h
  end

  def test_to_proto
    namespace = "my.namespace"

    contexts = Quonfig::Context.new({
                                     user: {
                                       id: 1,
                                       email: 'user-email'
                                     },
                                     team: {
                                       id: 2,
                                       name: 'team-name'
                                     }
                                   })

    assert_equal PrefabProto::ContextSet.new(
      contexts: [
        PrefabProto::Context.new(
          type: "user",
          values: {
            "id" => PrefabProto::ConfigValue.new(int: 1),
            "email" => PrefabProto::ConfigValue.new(string: "user-email")
          }
        ),
        PrefabProto::Context.new(
          type: "team",
          values: {
            "id" => PrefabProto::ConfigValue.new(int: 2),
            "name" => PrefabProto::ConfigValue.new(string: "team-name")
          }
        )
      ]
    ), contexts.to_proto(namespace)
  end

  def test_to_proto_with_parent
    global_context = { cpu: { count: 4, speed: '2.4GHz' }, clock: { timezone: 'UTC' }, magic: { key: "global-key" } }
    default_context = { 'prefab-api-key' => { 'user-id' => 123 } }

    Quonfig::Context.global_context = global_context
    Quonfig::Context.default_context = default_context

    Quonfig::Context.current = {
      user: { id: 2, email: 'parent-email' },
      magic: { key: 'parent-key', rabbits: 3 },
      clock: { timezone: 'PST' }
    }

    contexts = Quonfig::Context.join(hash: {
                                      user: {
                                        id: 1,
                                        email: 'user-email'
                                      },
                                      team: {
                                        id: 2,
                                        name: 'team-name'
                                      }
                                    }, id: :jit, parent: Quonfig::Context.current)

    expected = PrefabProto::ContextSet.new(
      contexts: [
        # Via global
        PrefabProto::Context.new(
          type: "cpu",
          values: {
            "count" => PrefabProto::ConfigValue.new(int: 4),
            "speed" => PrefabProto::ConfigValue.new(string: "2.4GHz")
          }
        ),
        # Via default
        PrefabProto::Context.new(
          type: "clock",
          values: {
            "timezone" => PrefabProto::ConfigValue.new(string: 'PST'),
          }
        ),
        # via current
        PrefabProto::Context.new(
          type: "magic",
          values: {
            "key" => PrefabProto::ConfigValue.new(string: 'parent-key'),
            "rabbits" => PrefabProto::ConfigValue.new(int: 3)
          }
        ),
        # via default
        PrefabProto::Context.new(
          type: "prefab-api-key",
          values: {
            "user-id" => PrefabProto::ConfigValue.new(int: 123)
          }
        ),
        # via jit
        PrefabProto::Context.new(
          type: "user",
          values: {
            "id" => PrefabProto::ConfigValue.new(int: 1),
            "email" => PrefabProto::ConfigValue.new(string: "user-email")
          }
        ),
        # via jit
        PrefabProto::Context.new(
          type: "team",
          values: {
            "id" => PrefabProto::ConfigValue.new(int: 2),
            "name" => PrefabProto::ConfigValue.new(string: "team-name")
          }
        ),
      ]
    )

    actual = contexts.to_proto("")

    assert_equal expected, actual
  end

  def test_parent_lookup
    global_context = { cpu: { count: 4, speed: '2.4GHz' }, clock: { timezone: 'UTC' } }
    default_context = { 'prefab-api-key' => { 'user-id' => 123 } }
    local_context = { clock: { timezone: 'PST' }, user: { name: 'Ted', email: 'ted@example.com' } }
    jit_context = { user: { name: 'Frank' } }

    Quonfig::Context.global_context = global_context
    Quonfig::Context.default_context = default_context
    Quonfig::Context.current = local_context

    context = Quonfig::Context.join(parent: Quonfig::Context.current, hash: jit_context, id: :jit)

    # This digs all the way to the global context
    assert_equal 4, context.get('cpu.count')
    assert_equal '2.4GHz', context.get('cpu.speed')

    # This digs to the default context
    assert_equal 123, context.get('prefab-api-key.user-id')

    # This digs to the local context
    assert_equal 'PST', context.get('clock.timezone')

    # This uses the jit context
    assert_equal 'Frank', context.get('user.name')

    # This is nil in the jit context because `user` was clobbered
    assert_nil context.get('user.email')
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
