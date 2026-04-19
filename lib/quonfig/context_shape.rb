module Quonfig
  class ContextShape
    MAPPING = {
      Integer => 1,
      String => 2,
      Float => 4,
      TrueClass => 5,
      FalseClass => 5,
      Array => 10,
    }.freeze

    # We default to String if the type isn't a primitive we support.
    # This is because we do a `to_s` in the CriteriaEvaluator.
    DEFAULT = MAPPING[String]

    def self.field_type_number(value)
      MAPPING.fetch(value.class, DEFAULT)
    end
  end
end
