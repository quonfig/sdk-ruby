# frozen_string_literal: true

module Quonfig
  module Errors
    class MissingEnvVarError < Quonfig::Error
      def initialize(message)
        super(message)
      end
    end
  end
end
