# frozen_string_literal: true

module Quonfig
  module Errors
    class TypeMismatchError < Quonfig::Error
      def initialize(key, expected, actual_value)
        super("Quonfig value for key '#{key}' expected #{expected}, got #{actual_value.class}: #{actual_value.inspect}")
      end
    end
  end
end
