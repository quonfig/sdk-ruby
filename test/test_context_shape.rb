# frozen_string_literal: true

require 'test_helper'

class TestContextShape < Minitest::Test
  class Email; end

  def test_field_type_number
    [
      [1, 1],
      [99999999999999999999999999999999999999999999, 1],
      [-99999999999999999999999999999999999999999999, 1],

      ['a', 2],
      ['99999999999999999999999999999999999999999999', 2],

      [1.0, 4],
      [99999999999999999999999999999999999999999999.0, 4],
      [-99999999999999999999999999999999999999999999.0, 4],

      [true, 5],
      [false, 5],

      [[], 10],
      [[1, 2, 3], 10],
      [['a', 'b', 'c'], 10],

      [Email.new, 2],
    ].each do |value, expected|
      actual = Quonfig::ContextShape.field_type_number(value)

      refute_nil actual, "Expected a value for input: #{value}"
      assert_equal expected, actual, "Expected #{expected} for #{value}"
    end
  end

  # If this test fails, it means that we've added a new type to the ConfigValue
  def test_mapping_is_exhaustive
    unsupported = [:bytes, :limit_definition, :log_level, :weighted_values, :int_range, :provided, :duration, :json, :schema]
    type_fields = PrefabProto::ConfigValue.descriptor.lookup_oneof("type").entries
    supported = type_fields.entries.reject do |entry|
      unsupported.include?(entry.name.to_sym)
    end.map(&:number)
    mapped = Quonfig::ContextShape::MAPPING.values.uniq

    unless mapped == supported
      raise "ContextShape MAPPING needs update: #{mapped} != #{supported}"
    end
  end
end
