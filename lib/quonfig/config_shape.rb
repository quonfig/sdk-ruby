# frozen_string_literal: true

module Quonfig
  # Decode-time shape check for config entries (qfg-krjt; the WS8
  # skip-one-bad-config rule, as sdk-go 2f6b98b, sdk-node qfg-goi1.10.1 and
  # sdk-python qfg-goi1.10.5).
  #
  # The store keeps raw JSON and the evaluator walks it as Hashes and Arrays,
  # so a config whose rule, criterion or default has the wrong shape, or whose
  # weighted value has a non-integer weight, would install and then raise
  # NoMethodError/TypeError out of every read of that key. Each delivery path
  # (HTTP, SSE, datadir) runs its configs through .filter instead: a bad entry
  # is skipped with a WARN naming its key, so the key reads as not found, and
  # the rest installs. If every entry fails, .filter raises AllInvalidError so
  # the payload is rejected and can never install as an empty workspace.
  module ConfigShape
    LOG = Quonfig::InternalLogger.new(self)

    # Raised by .filter when a non-empty payload has no loadable config.
    class AllInvalidError < StandardError; end

    module_function

    # Returns the configs that pass #problem, in order. +version+ is only used
    # in the log line.
    def filter(configs, logger: nil, version: nil)
      raise AllInvalidError, 'every config failed to load: configs is not a list' unless configs.is_a?(Array)

      log = logger || LOG
      first_problem = nil
      kept = configs.select do |cfg|
        reason = problem(cfg)
        next true if reason.nil?

        first_problem ||= reason
        log.warn "[quonfig] skipping config \"#{key_of(cfg)}\" that failed to load (version #{version}): " \
                 "#{reason}; other configs are unaffected"
        false
      end
      raise AllInvalidError, "every config failed to load (first: #{first_problem})" if kept.empty? && first_problem

      kept
    end

    # nil when +cfg+ has a shape the evaluator can walk, else a short reason.
    def problem(cfg)
      return 'config entry is not an object' unless cfg.is_a?(Hash)

      key = field(cfg, 'key')
      return 'config entry has no key' unless key.is_a?(String) && !key.empty?

      default = field(cfg, 'default')
      unless default.nil?
        return 'default is not an object' unless default.is_a?(Hash)

        reason = rules_problem(field(default, 'rules'), 'default')
        return reason if reason
      end

      env = field(cfg, 'environment')
      return nil if env.nil?
      return 'environment is not an object' unless env.is_a?(Hash)

      rules_problem(field(env, 'rules'), 'environment')
    end

    def rules_problem(rules, where)
      return nil if rules.nil?
      return "#{where}.rules is not a list" unless rules.is_a?(Array)

      rules.each_with_index do |rule, i|
        reason = rule_problem(rule)
        return "#{where}.rules[#{i}]: #{reason}" if reason
      end
      nil
    end

    def rule_problem(rule)
      return 'rule is not an object' unless rule.is_a?(Hash)

      criteria = field(rule, 'criteria')
      unless criteria.nil?
        return 'criteria is not a list' unless criteria.is_a?(Array)

        criteria.each_with_index do |criterion, i|
          return "criteria[#{i}] is not an object" unless criterion.is_a?(Hash)

          match = field(criterion, 'valueToMatch')
          return "criteria[#{i}].valueToMatch is not an object" unless match.nil? || match.is_a?(Hash)
        end
      end

      value_problem(field(rule, 'value'))
    end

    def value_problem(value)
      return nil if value.nil?
      return 'value is not an object' unless value.is_a?(Hash)
      return nil unless field(value, 'type') == 'weighted_values'

      weighted = field(value, 'value')
      return 'weighted_values value is not an object' unless weighted.is_a?(Hash)

      entries = field(weighted, 'weightedValues')
      return nil if entries.nil?
      return 'weightedValues is not a list' unless entries.is_a?(Array)

      entries.each_with_index do |entry, i|
        return "weightedValues[#{i}] is not an object" unless entry.is_a?(Hash)

        # A missing weight counts as 0; a present one must be an Integer
        # (sdk-go's int weight fails json.Unmarshal the same way).
        next unless entry.key?('weight') || entry.key?(:weight)
        next if field(entry, 'weight').is_a?(Integer)

        return "weightedValues[#{i}].weight must be an integer (got #{field(entry, 'weight').class})"
      end
      nil
    end

    def field(hash, name)
      return hash[name] if hash.key?(name)

      hash[name.to_sym]
    end

    def key_of(cfg)
      return '' unless cfg.is_a?(Hash)

      key = field(cfg, 'key')
      key.is_a?(String) ? key : ''
    end
  end
end
