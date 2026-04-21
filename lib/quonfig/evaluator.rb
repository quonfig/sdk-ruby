# frozen_string_literal: true

require 'date'

module Quonfig
  # Evaluates configs pulled from a ConfigStore against a Context.
  #
  # Public API shape mirrors sdk-node's Evaluator (src/evaluator.ts):
  #   evaluator = Quonfig::Evaluator.new(store)
  #   result    = evaluator.evaluate_config(cfg, context, resolver: resolver)
  #
  # Since qfg-dk6.10 this class owns the full operator matrix against the JSON
  # Criterion shape (propertyName / operator / valueToMatch). It accepts
  # configs in either of two shapes:
  #
  # - The ConfigResponse hash produced by Quonfig::Datadir.to_config_response
  #   and IntegrationTestHelpers.to_config_response — symbol or string keys at
  #   the top level (id, key, type, value_type/valueType, default, environment)
  #   with JSON rules/criteria inside as plain hashes with string keys.
  # The legacy protobuf-shaped Config object is no longer supported.
  #
  # evaluate_config returns an EvalResult that exposes the matched value via
  # #unwrapped_value (coerced into a native Ruby type per value.type) and
  # #value (the raw JSON Value hash). If nothing matches it returns nil, which
  # Resolver#get relays to callers.
  class Evaluator
    # Operator constants — kept as strings for direct comparison with the wire
    # format (no symbol conversion on the hot path).
    OP_NOT_SET                         = 'NOT_SET'
    OP_ALWAYS_TRUE                     = 'ALWAYS_TRUE'
    OP_PROP_IS_ONE_OF                  = 'PROP_IS_ONE_OF'
    OP_PROP_IS_NOT_ONE_OF              = 'PROP_IS_NOT_ONE_OF'
    OP_PROP_STARTS_WITH_ONE_OF         = 'PROP_STARTS_WITH_ONE_OF'
    OP_PROP_DOES_NOT_START_WITH_ONE_OF = 'PROP_DOES_NOT_START_WITH_ONE_OF'
    OP_PROP_ENDS_WITH_ONE_OF           = 'PROP_ENDS_WITH_ONE_OF'
    OP_PROP_DOES_NOT_END_WITH_ONE_OF   = 'PROP_DOES_NOT_END_WITH_ONE_OF'
    OP_PROP_CONTAINS_ONE_OF            = 'PROP_CONTAINS_ONE_OF'
    OP_PROP_DOES_NOT_CONTAIN_ONE_OF    = 'PROP_DOES_NOT_CONTAIN_ONE_OF'
    OP_PROP_MATCHES                    = 'PROP_MATCHES'
    OP_PROP_DOES_NOT_MATCH             = 'PROP_DOES_NOT_MATCH'
    OP_HIERARCHICAL_MATCH              = 'HIERARCHICAL_MATCH'
    OP_IN_INT_RANGE                    = 'IN_INT_RANGE'
    OP_PROP_GREATER_THAN               = 'PROP_GREATER_THAN'
    OP_PROP_GREATER_THAN_OR_EQUAL      = 'PROP_GREATER_THAN_OR_EQUAL'
    OP_PROP_LESS_THAN                  = 'PROP_LESS_THAN'
    OP_PROP_LESS_THAN_OR_EQUAL         = 'PROP_LESS_THAN_OR_EQUAL'
    OP_PROP_BEFORE                     = 'PROP_BEFORE'
    OP_PROP_AFTER                      = 'PROP_AFTER'
    OP_PROP_SEMVER_LESS_THAN           = 'PROP_SEMVER_LESS_THAN'
    OP_PROP_SEMVER_EQUAL               = 'PROP_SEMVER_EQUAL'
    OP_PROP_SEMVER_GREATER_THAN        = 'PROP_SEMVER_GREATER_THAN'
    OP_IN_SEG                          = 'IN_SEG'
    OP_NOT_IN_SEG                      = 'NOT_IN_SEG'

    MAGIC_CURRENT_TIME_PROPS = %w[quonfig.current-time prefab.current-time reforge.current-time].freeze

    attr_reader :store
    attr_accessor :project_env_id, :env_id

    def initialize(store, project_env_id: 0, env_id: nil, namespace: nil, base_client: nil)
      @store = store
      @project_env_id = project_env_id
      @env_id = env_id
      @namespace = namespace
      @base_client = base_client
    end

    # Evaluate +config+ against +context+ and return an EvalResult (or nil if
    # no rule matched). +context+ may be a Quonfig::Context or a plain Hash.
    def evaluate_config(config, context, resolver: nil)
      ctx = coerce_context(context)
      env = config_environment(config)

      if env && @env_id && env_id_of(env) == @env_id
        match = evaluate_rules(env_rules(env), ctx, config)
        return match if match
      end

      default_rules = default_rules_of(config)
      match = evaluate_rules(default_rules, ctx, config)
      return match if match

      nil
    end

    private

    # --- Shape coercion helpers -----------------------------------------

    def coerce_context(context)
      return context if context.is_a?(Quonfig::Context)
      return Quonfig::Context.new({}) if context.nil?

      Quonfig::Context.new(context)
    end

    def hget(hash, *keys)
      return nil if hash.nil?

      keys.each do |k|
        return hash[k] if hash.key?(k)
        sk = k.to_s
        return hash[sk] if hash.key?(sk)
        sym = k.to_sym
        return hash[sym] if hash.key?(sym)
      end
      nil
    end

    def default_rules_of(config)
      default = hget(config, :default)
      rules = hget(default, :rules) || []
      Array(rules)
    end

    def config_environment(config)
      hget(config, :environment)
    end

    def env_id_of(env)
      hget(env, :id)
    end

    def env_rules(env)
      Array(hget(env, :rules) || [])
    end

    # --- Rule evaluation ------------------------------------------------

    def evaluate_rules(rules, context, config)
      rules.each_with_index do |rule, index|
        criteria = Array(hget(rule, :criteria) || [])
        next unless all_criteria_match?(criteria, context, config)

        value_hash = hget(rule, :value)
        return EvalResult.new(value: value_hash, rule_index: index, config: config)
      end
      nil
    end

    def all_criteria_match?(criteria, context, config)
      criteria.all? { |c| evaluate_criterion(c, context, config) }
    end

    # --- Per-operator evaluation ---------------------------------------
    #
    # Faithful port of sdk-node/src/operators.ts evaluateCriterion. Matches
    # context-exists / missing-context semantics (e.g. PROP_IS_NOT_ONE_OF is
    # true when context is missing).
    def evaluate_criterion(criterion, context, config)
      property_name = hget(criterion, :propertyName) || ''
      operator = hget(criterion, :operator)
      match_value = hget(criterion, :valueToMatch)

      context_value, context_exists = lookup_context(context, property_name)

      case operator
      when OP_NOT_SET, nil
        return false

      when OP_ALWAYS_TRUE
        return true

      when OP_PROP_IS_ONE_OF, OP_PROP_IS_NOT_ONE_OF
        if context_exists && match_value
          match_strings = get_string_list(match_value)
          if match_strings
            context_strings = to_string_slice(context_value)
            match_found = context_strings.any? { |cv| match_strings.include?(cv) }
            return match_found == (operator == OP_PROP_IS_ONE_OF)
          end
        end
        return operator == OP_PROP_IS_NOT_ONE_OF

      when OP_PROP_STARTS_WITH_ONE_OF, OP_PROP_DOES_NOT_START_WITH_ONE_OF
        if context_exists && match_value
          match_strings = get_string_list(match_value)
          if match_strings
            cv = to_s_nil(context_value)
            match_found = match_strings.any? { |p| cv.start_with?(p) }
            return match_found == (operator == OP_PROP_STARTS_WITH_ONE_OF)
          end
        end
        return operator == OP_PROP_DOES_NOT_START_WITH_ONE_OF

      when OP_PROP_ENDS_WITH_ONE_OF, OP_PROP_DOES_NOT_END_WITH_ONE_OF
        if context_exists && match_value
          match_strings = get_string_list(match_value)
          if match_strings
            cv = to_s_nil(context_value)
            match_found = match_strings.any? { |p| cv.end_with?(p) }
            return match_found == (operator == OP_PROP_ENDS_WITH_ONE_OF)
          end
        end
        return operator == OP_PROP_DOES_NOT_END_WITH_ONE_OF

      when OP_PROP_CONTAINS_ONE_OF, OP_PROP_DOES_NOT_CONTAIN_ONE_OF
        if context_exists && match_value
          match_strings = get_string_list(match_value)
          if match_strings
            cv = to_s_nil(context_value)
            match_found = match_strings.any? { |p| cv.include?(p) }
            return match_found == (operator == OP_PROP_CONTAINS_ONE_OF)
          end
        end
        return operator == OP_PROP_DOES_NOT_CONTAIN_ONE_OF

      when OP_PROP_MATCHES, OP_PROP_DOES_NOT_MATCH
        mv = hget(match_value, :value)
        if context_exists && context_value.is_a?(String) && mv.is_a?(String)
          begin
            re = Regexp.new(mv)
            matched = re.match?(context_value)
            return matched == (operator == OP_PROP_MATCHES)
          rescue RegexpError
            return false
          end
        end
        return false

      when OP_HIERARCHICAL_MATCH
        if context_exists && match_value
          cv = to_s_nil(context_value)
          mv = to_s_nil(hget(match_value, :value))
          return cv.start_with?(mv)
        end
        return false

      when OP_IN_INT_RANGE
        if context_exists && match_value
          start_v, end_v = extract_int_range(match_value)
          num_val = to_float(context_value)
          return num_val >= start_v && num_val < end_v unless num_val.nil?
        end
        return false

      when OP_PROP_GREATER_THAN, OP_PROP_GREATER_THAN_OR_EQUAL,
           OP_PROP_LESS_THAN, OP_PROP_LESS_THAN_OR_EQUAL
        if context_exists && match_value && context_value.is_a?(Numeric)
          mv = hget(match_value, :value)
          return false unless numeric_value?(mv)

          cmp = compare_numbers(context_value, mv)
          return false if cmp.nil?

          case operator
          when OP_PROP_GREATER_THAN          then return cmp > 0
          when OP_PROP_GREATER_THAN_OR_EQUAL then return cmp >= 0
          when OP_PROP_LESS_THAN             then return cmp < 0
          when OP_PROP_LESS_THAN_OR_EQUAL    then return cmp <= 0
          end
        end
        return false

      when OP_PROP_BEFORE, OP_PROP_AFTER
        if context_exists && match_value
          context_millis = date_to_millis(context_value)
          match_millis = date_to_millis(hget(match_value, :value))
          if context_millis && match_millis
            return operator == OP_PROP_BEFORE ? context_millis < match_millis : context_millis > match_millis
          end
        end
        return false

      when OP_PROP_SEMVER_LESS_THAN, OP_PROP_SEMVER_EQUAL, OP_PROP_SEMVER_GREATER_THAN
        mv = hget(match_value, :value)
        if context_exists && context_value.is_a?(String) && mv.is_a?(String)
          sv_ctx = SemanticVersion.parse_quietly(context_value)
          sv_mv  = SemanticVersion.parse_quietly(mv)
          if sv_ctx && sv_mv
            cmp = (sv_ctx <=> sv_mv)
            case operator
            when OP_PROP_SEMVER_LESS_THAN    then return cmp < 0
            when OP_PROP_SEMVER_EQUAL        then return cmp == 0
            when OP_PROP_SEMVER_GREATER_THAN then return cmp > 0
            end
          end
        end
        return false

      when OP_IN_SEG, OP_NOT_IN_SEG
        if match_value
          segment_key = to_s_nil(hget(match_value, :value))
          found, result = resolve_segment(segment_key, context)
          return operator == OP_NOT_IN_SEG unless found

          return result == (operator == OP_IN_SEG)
        end
        return operator == OP_NOT_IN_SEG

      else
        return false
      end
    end

    def lookup_context(context, property_name)
      if MAGIC_CURRENT_TIME_PROPS.include?(property_name)
        return [(Time.now.utc.to_f * 1000).to_i, true]
      end

      if property_name.nil? || property_name.empty?
        return [nil, false]
      end

      value = context.get(property_name)
      [value, !value.nil?]
    end

    # --- Segment resolution -------------------------------------------

    def resolve_segment(segment_key, context)
      return [false, false] if segment_key.nil? || segment_key.empty?

      seg_config = @store.get(segment_key)
      return [false, false] if seg_config.nil?

      # Segments have no environment-specific rules in the JSON shape; we
      # evaluate against default rules only (mirrors sdk-node behaviour —
      # evaluate_config with env_id='' falls through to default).
      match = evaluate_rules(default_rules_of(seg_config), context, seg_config)
      return [false, false] if match.nil?

      raw = match.raw_value
      [true, !!raw]
    end

    # --- Type coercion helpers ----------------------------------------

    def to_s_nil(v)
      return '' if v.nil?

      v.to_s
    end

    def to_string_slice(v)
      return [] if v.nil?
      return v.map { |i| to_s_nil(i) } if v.is_a?(Array)

      [to_s_nil(v)]
    end

    def get_string_list(value_hash)
      return nil if value_hash.nil?

      raw = hget(value_hash, :value)
      return nil unless raw.is_a?(Array)

      raw.map { |i| to_s_nil(i) }
    end

    def numeric_value?(v)
      return true if v.is_a?(Numeric)
      return false unless v.is_a?(String)

      stripped = v.strip
      return false if stripped.empty?

      !Float(stripped, exception: false).nil?
    end

    def to_float(v)
      return v.to_f if v.is_a?(Numeric)
      return nil unless v.is_a?(String)

      f = Float(v, exception: false)
      f
    end

    def compare_numbers(a, b)
      af = to_float(a)
      bf = to_float(b)
      return nil if af.nil? || bf.nil?

      af <=> bf
    end

    def extract_int_range(value_hash)
      min = -(2**53) + 1  # approx Number.MIN_SAFE_INTEGER
      max = (2**53) - 1
      raw = hget(value_hash, :value)
      return [min, max] unless raw.is_a?(Hash)

      start_v = to_float(hget(raw, :start))
      end_v = to_float(hget(raw, :end))
      [start_v || min, end_v || max]
    end

    def date_to_millis(val)
      case val
      when Integer, Float
        val.to_i
      when String
        # Try ISO-8601 / RFC3339 first, fall back to integer-string.
        begin
          t = DateTime.parse(val)
          return (t.to_time.to_f * 1000).to_i
        rescue ArgumentError, TypeError
          # not a date; try integer
        end
        n = Integer(val, exception: false)
        n
      else
        nil
      end
    end
  end

  # Result of a matched config evaluation. Provides the caller with both the
  # raw JSON Value hash (#value) and a coerced Ruby value (#unwrapped_value).
  # The test suite and integration helpers consume both shapes.
  class EvalResult
    attr_reader :value, :rule_index, :config

    def initialize(value:, rule_index:, config:)
      @value = value
      @rule_index = rule_index
      @config = config
    end

    # Raw underlying value without type coercion.
    def raw_value
      return nil if @value.nil?

      @value[:value] || @value['value']
    end

    # The declared Value type ('string', 'int', 'bool', ...). Nil if unset.
    def type
      return nil if @value.nil?

      @value[:type] || @value['type']
    end

    # Ruby-native value after type coercion. Mirrors sdk-node Resolver#unwrapValue.
    def unwrapped_value
      raw = raw_value
      case type
      when 'bool'        then !!raw
      when 'int'
        return raw if raw.is_a?(Integer)
        return raw.to_i if raw.is_a?(Numeric)
        Integer(raw.to_s, 10)
      when 'double'
        return raw.to_f if raw.is_a?(Numeric)
        Float(raw.to_s)
      when 'string'      then raw.to_s
      when 'string_list' then raw.is_a?(Array) ? raw.map(&:to_s) : []
      when 'log_level'   then raw.is_a?(Numeric) ? raw : raw.to_s
      when 'duration'    then raw.to_s
      when 'json'
        # JSON values must be native JS/Ruby types on the wire.
        raw
      else
        raw
      end
    end

    # Convenience for callers that don't care about coercion — mirrors
    # the {type, value} shape sdk-node emits.
    def value_type
      type
    end
  end
end
