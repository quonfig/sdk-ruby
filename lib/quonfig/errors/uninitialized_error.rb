# frozen_string_literal: true

module Quonfig
  module Errors
    class UninitializedError < Quonfig::Error
      def initialize(key=nil)
        message = "Use Quonfig.initialize before calling Quonfig.get #{key}"

        super(message)
      end
    end
  end
end
