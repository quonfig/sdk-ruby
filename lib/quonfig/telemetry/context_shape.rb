# frozen_string_literal: true

module Quonfig
  module Telemetry
    # Maps a context property value to the numeric field-type code used by
    # api-telemetry. The numbers match the codes used by sdk-node and sdk-go
    # (and historically the Prefab proto ConfigValue oneof):
    #
    #   1  = integer
    #   2  = string
    #   4  = double (float)
    #   5  = boolean
    #   10 = string list (array)
    class ContextShape
      MAPPING = {
        Integer => 1,
        String => 2,
        Float => 4,
        TrueClass => 5,
        FalseClass => 5,
        Array => 10
      }.freeze

      # We default to 2 (String) for unknown types — criteria evaluation
      # treats them as strings via #to_s.
      DEFAULT = MAPPING[String]

      def self.field_type_number(value)
        MAPPING.fetch(value.class, DEFAULT)
      end
    end
  end
end
