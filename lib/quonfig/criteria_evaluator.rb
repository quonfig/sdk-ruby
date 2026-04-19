# frozen_string_literal: true

# rubocop:disable Naming/MethodName
# We're intentionally keeping the UPCASED method names to match the protobuf
# and avoid wasting CPU cycles lowercasing things
module Quonfig
  # This class evaluates a config's criteria. `evaluate` returns the value of
  # the first match based on the provided properties.
  class CriteriaEvaluator
    LOG = Quonfig::InternalLogger.new(self)
    NAMESPACE_KEY = 'NAMESPACE'
    NO_MATCHING_ROWS = [].freeze

    def initialize(config, project_env_id:, resolver:, namespace:, base_client:)
      @config = config
      @project_env_id = project_env_id
      @resolver = resolver
      @namespace = namespace
      @base_client = base_client
    end

    def evaluate(properties)
      rtn = evaluate_for_env(@project_env_id, properties) ||
        evaluate_for_env(0, properties)
      LOG.trace {
        "Eval Key #{@config.key} Result #{rtn&.reportable_value} with #{properties.to_h}"
      } unless @config.config_type == :LOG_LEVEL
      rtn
    end

    def all_criteria_match?(conditional_value, props)
      conditional_value.criteria.all? do |criterion|
        public_send(criterion.operator, criterion, props)
      end
    end

    def IN_SEG(criterion, properties)
      in_segment?(criterion, properties)
    end

    def NOT_IN_SEG(criterion, properties)
      !in_segment?(criterion, properties)
    end

    def ALWAYS_TRUE(_criterion, _properties)
      true
    end

    def PROP_IS_ONE_OF(criterion, properties)
      Array(value_from_properties(criterion, properties)).any? do |prop|
        matches?(criterion, prop, properties)
      end
    end

    def PROP_IS_NOT_ONE_OF(criterion, properties)
      !PROP_IS_ONE_OF(criterion, properties)
    end

    def PROP_ENDS_WITH_ONE_OF(criterion, properties)
      prop_ends_with_one_of?(criterion, value_from_properties(criterion, properties))
    end

    def PROP_DOES_NOT_END_WITH_ONE_OF(criterion, properties)
      !PROP_ENDS_WITH_ONE_OF(criterion, properties)
    end

    def PROP_STARTS_WITH_ONE_OF(criterion, properties)
      prop_starts_with_one_of?(criterion, value_from_properties(criterion, properties))
    end

    def PROP_DOES_NOT_START_WITH_ONE_OF(criterion, properties)
      !PROP_STARTS_WITH_ONE_OF(criterion, properties)
    end

    def PROP_CONTAINS_ONE_OF(criterion, properties)
      prop_contains_one_of?(criterion, value_from_properties(criterion, properties))
    end

    def PROP_DOES_NOT_CONTAIN_ONE_OF(criterion, properties)
      !PROP_CONTAINS_ONE_OF(criterion, properties)
    end

    def HIERARCHICAL_MATCH(criterion, properties)
      value = value_from_properties(criterion, properties)
      value&.start_with?(criterion.value_to_match.string)
    end

    def IN_INT_RANGE(criterion, properties)
      value = value_from_properties(criterion, properties)
      value && value >= criterion.value_to_match.int_range.start && value < criterion.value_to_match.int_range.end
    end

    def PROP_MATCHES(criterion, properties)
      result = check_regex_match(criterion, properties)
      if result.error
        false
      else
        result.matched
      end
    end

    def PROP_DOES_NOT_MATCH(criterion, properties)
      result = check_regex_match(criterion, properties)
      if result.error
        false
      else
        !result.matched
      end
    end

    def PROP_LESS_THAN(criterion, properties)
      evaluate_number_comparison(criterion, properties, COMPARE_TO_OPERATORS[:less_than]).matched
    end

    def PROP_LESS_THAN_OR_EQUAL(criterion, properties)
      evaluate_number_comparison(criterion, properties, COMPARE_TO_OPERATORS[:less_than_or_equal]).matched
    end

    def PROP_GREATER_THAN(criterion, properties)
      evaluate_number_comparison(criterion, properties, COMPARE_TO_OPERATORS[:greater_than]).matched
    end

    def PROP_GREATER_THAN_OR_EQUAL(criterion, properties)
      evaluate_number_comparison(criterion, properties,COMPARE_TO_OPERATORS[:greater_than_or_equal]) .matched
    end

    def PROP_BEFORE(criterion, properties)
      evaluate_date_comparison(criterion, properties, COMPARE_TO_OPERATORS[:less_than]).matched
    end

    def PROP_AFTER(criterion, properties)
      evaluate_date_comparison(criterion, properties, COMPARE_TO_OPERATORS[:greater_than]).matched
    end

    def PROP_SEMVER_LESS_THAN(criterion, properties)
      evaluate_semver_comparison(criterion, properties, COMPARE_TO_OPERATORS[:less_than]).matched
    end

    def PROP_SEMVER_EQUAL(criterion, properties)
      evaluate_semver_comparison(criterion, properties, COMPARE_TO_OPERATORS[:equal_to]).matched
    end

    def PROP_SEMVER_GREATER_THAN(criterion, properties)
      evaluate_semver_comparison(criterion, properties, COMPARE_TO_OPERATORS[:greater_than]).matched
    end

    def value_from_properties(criterion, properties)
      case criterion.property_name
      when NAMESPACE_KEY
        @namespace
      when 'prefab.current-time','reforge.current-time'
        Time.now.utc.to_i * 1000
      else
        properties.get(criterion.property_name)
      end
    end

    COMPARE_TO_OPERATORS = {
      less_than_or_equal: -> cmp {  cmp <= 0 },
      less_than: -> cmp {  cmp < 0 },
      equal_to: -> cmp {  cmp == 0 },
      greater_than: -> cmp {  cmp > 0 },
      greater_than_or_equal: -> cmp {  cmp >= 0 },
    }

    private

    def evaluate_semver_comparison(criterion, properties, predicate)
      context_version = value_from_properties(criterion, properties)&.then { |v| SemanticVersion.parse_quietly(v) }
      config_version = criterion.value_to_match&.string&.then {|v| SemanticVersion.parse_quietly(criterion.value_to_match.string) }

      unless context_version && config_version
        return MatchResult.error
      end
      predicate.call(context_version <=> config_version) ? MatchResult.matched : MatchResult.not_matched
    end

    def evaluate_date_comparison(criterion, properties, predicate)
      context_millis = as_millis(value_from_properties(criterion, properties))
      config_millis = as_millis(Quonfig::ConfigValueUnwrapper.deepest_value(criterion.value_to_match, @config,
                                                                           properties, @resolver).unwrap)

      unless config_millis && context_millis
        return MatchResult.error
      end

      predicate.call(context_millis <=> config_millis) ? MatchResult.matched : MatchResult.not_matched
    end

    def evaluate_number_comparison(criterion, properties, predicate)
      context_value = value_from_properties(criterion, properties)
      value_to_match = extract_numeric_value(criterion.value_to_match)

      return MatchResult.error if value_to_match.nil?
      return MatchResult.error unless context_value.is_a?(Numeric)

      # Compare the values and apply the predicate method
      comparison_result = context_value <=> value_to_match
      return MatchResult.error if comparison_result.nil?

      predicate.call(comparison_result) ? MatchResult.matched : MatchResult.not_matched
    end

    def extract_numeric_value(config_value)
      case config_value.type
      when :int
        config_value.int
      when :double
        config_value.double
      end
    end

    def as_millis(obj)
      if obj.is_a?(Numeric)
        return obj.to_int if obj.respond_to?(:to_int)
      end
      if obj.is_a?(String)
        Time.iso8601(obj).utc.to_i * 1000 rescue nil
      end
    end


    def evaluate_for_env(env_id, properties)
      @config.rows.each_with_index do |row, index|
        next unless row.project_env_id == env_id

        row.values.each_with_index do |conditional_value, value_index|
          next unless all_criteria_match?(conditional_value, properties)

          # we compute the row index here as if the @config.rows were sorted with the default environment (id=0) last. the client would only ever see one or two rows
          # 2 rows if there's a default env rule and a targed env rule
          # 1 row if there's only a default env rule or only a target env rule
          config_row_index = if @config.rows.length == 1
                               0
                             elsif row.project_env_id != 0
                               0
                             else
                               1
                             end


          return Quonfig::Evaluation.new(
            config: @config,
            value: conditional_value.value,
            value_index: value_index,
            config_row_index: config_row_index,
            context: properties,
            resolver: @resolver
          )
        end
      end

      nil
    end

    def in_segment?(criterion, properties)
      segment = @resolver.get(criterion.value_to_match.string, properties)

      LOG.info("Segment #{criterion.value_to_match.string} not found") unless segment

      segment&.report_and_return(@base_client.evaluation_summary_aggregator)
    end

    def matches?(criterion, value, properties)
      criterion_value_or_values = Quonfig::ConfigValueUnwrapper.deepest_value(criterion.value_to_match, @config,
                                                                             properties, @resolver).unwrap

      case criterion_value_or_values
      when Google::Protobuf::RepeatedField
        # we to_s the value from properties for comparison because the
        # criterion_value_or_values is a list of strings
        criterion_value_or_values.include?(value.to_s)
      else
        criterion_value_or_values == value
      end
    end

    def prop_ends_with_one_of?(criterion, value)
      return false unless value

      criterion.value_to_match.string_list.values.any? do |ending|
        value.end_with?(ending)
      end
    end

    def prop_starts_with_one_of?(criterion, value)
      return false unless value

      criterion.value_to_match.string_list.values.any? do |beginning|
        value.start_with?(beginning)
      end
    end

    def prop_contains_one_of?(criterion, value)
      return false unless value

      criterion.value_to_match.string_list.values.any? do |substring|
        value.include?(substring)
      end
    end

    def check_regex_match(criterion, properties)
      begin
        regex_definition = Quonfig::ConfigValueUnwrapper.deepest_value(criterion.value_to_match, @config.key,
                                                                      properties, @resolver).unwrap

        return MatchResult.error unless regex_definition.is_a?(String)

        value = value_from_properties(criterion, properties)

        regex = compile_regex_safely(ensure_anchored_regex(regex_definition))
        return MatchResult.error unless regex

        matches = regex.match?(value.to_s)
        matches ? MatchResult.matched : MatchResult.not_matched
      rescue RegexpError
        MatchResult.error
      end
    end

    def compile_regex_safely(pattern)
      begin
        Regexp.new(pattern)
      rescue RegexpError
        nil
      end
    end

    def ensure_anchored_regex(pattern)
      return pattern if pattern.start_with?("^") && pattern.end_with?("$")

      "^#{pattern}$"
    end

    class MatchResult
      attr_reader :matched, :error

      def self.matched
        new(matched: true)
      end

      def self.not_matched
        new(matched: false)
      end

      def self.error
        new(matched: false, error: true)
      end

      def initialize(matched:, error: false)
        @matched = matched
        @error = error
      end
    end
  end
end
# rubocop:enable Naming/MethodName
