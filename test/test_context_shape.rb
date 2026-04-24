# frozen_string_literal: true

require 'test_helper'

class TestContextShape < Minitest::Test
  class Email; end

  def test_field_type_number
    [
      [1, 1],
      [99_999_999_999_999_999_999_999_999_999_999_999_999_999_999, 1],
      [-99_999_999_999_999_999_999_999_999_999_999_999_999_999_999, 1],

      ['a', 2],
      ['99999999999999999999999999999999999999999999', 2],

      [1.0, 4],
      [99_999_999_999_999_999_999_999_999_999_999_999_999_999_999.0, 4],
      [-99_999_999_999_999_999_999_999_999_999_999_999_999_999_999.0, 4],

      [true, 5],
      [false, 5],

      [[], 10],
      [[1, 2, 3], 10],
      [%w[a b c], 10],

      # Unknown / custom types fall back to "string" (2).
      [Email.new, 2]
    ].each do |value, expected|
      actual = Quonfig::Telemetry::ContextShape.field_type_number(value)

      refute_nil actual, "Expected a value for input: #{value.inspect}"
      assert_equal expected, actual, "Expected #{expected} for #{value.inspect}"
    end
  end
end
