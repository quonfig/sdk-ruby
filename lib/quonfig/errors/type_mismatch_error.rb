# frozen_string_literal: true

module Quonfig
  module Errors
    class TypeMismatchError < Quonfig::Error
      # The message names the key, the expected type and the actual value's
      # class only. The value itself is never interpolated: it can be a
      # decrypted secret, and exception messages end up in logs and error
      # trackers (qfg-goi1.2.11).
      def initialize(key, expected, actual_value)
        super("Quonfig value for key '#{key}' expected #{expected}, got #{actual_value.class}")
      end
    end
  end
end
