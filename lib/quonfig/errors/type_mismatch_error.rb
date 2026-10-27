# frozen_string_literal: true

module Quonfig
  module Errors
    class TypeMismatchError < Quonfig::Error
      # The message names the key, the expected type and the actual value's
      # class only. The value itself is never interpolated: it can be a
      # decrypted secret, and exception messages end up in logs and error
      # trackers (qfg-goi1.2.11).
      # +actual_type+, when given, is the config's declared value type
      # ('string', 'duration', ...) and is named instead of the Ruby class.
      def initialize(key, expected, actual_value, actual_type: nil)
        got = actual_type ? "a #{actual_type} value" : actual_value.class
        super("Quonfig value for key '#{key}' expected #{expected}, got #{got}")
      end
    end
  end
end
