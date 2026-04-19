# frozen_string_literal: true

module Quonfig
  # Computes the *why* of an evaluation — the symbol that explains which code path
  # selected the returned value. Mirrors sdk-node/src/reason.ts.
  #
  #   :DEFAULT     — config has no targeting rules; matched value is the static default
  #   :RULE_MATCH  — at least one targeting rule exists on the config (the matched
  #                  conditional may itself be ALWAYS_TRUE, but the *config* is targeted)
  #   :SPLIT       — matched value came from a non-default weighted variant
  #   :ERROR       — evaluation failed
  #   :UNKNOWN     — unable to determine
  module Reason
    UNKNOWN    = :UNKNOWN
    DEFAULT    = :DEFAULT
    RULE_MATCH = :RULE_MATCH
    SPLIT      = :SPLIT
    ERROR      = :ERROR

    module_function

    def compute(config:, conditional_value:, weighted_value_index: nil)
      return SPLIT if weighted_value_index && weighted_value_index.positive?
      return RULE_MATCH if targeting_rules?(config)
      return RULE_MATCH if non_always_true_criteria?(conditional_value)
      DEFAULT
    end

    def targeting_rules?(config)
      config.rows.any? do |row|
        row.values.any? { |cv| non_always_true_criteria?(cv) }
      end
    end

    def non_always_true_criteria?(conditional_value)
      conditional_value.criteria.any? { |c| c.operator != :ALWAYS_TRUE }
    end
  end
end
