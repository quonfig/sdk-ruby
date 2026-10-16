# frozen_string_literal: true

require 'yaml'

# Expectation loading and the per-tick expectation step for the cross-SDK chaos
# harness, shared by the default suite (chaos/test_chaos.rb) and the
# failover/ordering suite (chaos/failover_chaos.rb). Pure: no toxiproxy, no
# client, so it is unit-tested in test/test_chaos_expectations.rb.
#
# Contract: integration-test-data chaos/README.md "Timeline rules (every
# harness)" and scenario.schema.json (qfg-goi1.7).

module Quonfig
  module Chaos
    module Expectations
      class UnknownKeyError < StandardError; end

      # Every key an expectation may carry (mirrors the ITD schema's
      # additionalProperties: false). Anything else fails the run (rule 4).
      KNOWN_KEYS = %w[within_ms assert must_hold_for_ms after_ms].freeze

      module_function

      # Parse one scenario YAML file and reject unknown expectation keys.
      # A YAML syntax error raises Psych::SyntaxError; an unknown key raises
      # UnknownKeyError naming the key. Neither is a warning.
      def load_scenario_file(path)
        doc = YAML.safe_load_file(path, aliases: true)
        validate_keys!(doc, path)
        doc
      end

      def validate_keys!(doc, source)
        return unless doc.is_a?(Hash)

        (doc['tests'] || []).each do |run|
          (run['expectations'] || []).each_with_index do |exp, i|
            unknown = (exp || {}).keys.map(&:to_s) - KNOWN_KEYS
            next if unknown.empty?

            raise UnknownKeyError,
                  "#{source}: test #{run['name'].inspect} exp[#{i}]: unknown expectation " \
                  "key(s) #{unknown.join(', ')} (allowed: #{KNOWN_KEYS.join(', ')})"
          end
        end
      end

      # +skip_only+ marks an expression whose every leaf is unevaluable by this
      # rig (server_metric): SKIPPED is decided by shape, not time.
      def new_state(idx, exp, skip_only: false)
        {
          idx: idx, exp: exp, passed: false, failed: false, skipped: false,
          skip_only: skip_only, hit_at: nil, held_since: nil, passed_at: nil,
          last_reason: '', skipped_leaves: []
        }
      end

      def after_ms(exp)
        (exp['after_ms'] || 0).to_i
      end

      def terminal?(state)
        state[:passed] || state[:failed] || state[:skipped]
      end

      # Advance one expectation by one tick. +elapsed_ms+ is ms since t=0,
      # +now_ms+ a monotonic-enough clock for the hold. The block evaluates the
      # assert and returns [status, reason, skipped_leaves], status one of
      # :pass, :fail or :skip.
      #
      # Rule 1: while elapsed < after_ms the block is not called, no hold
      # starts, nothing is terminal. within_ms is unchanged: the hold must
      # complete by it. A skip-only expression is SKIPPED regardless of
      # after_ms (shape-based; its evaluation reads no probe state).
      def step(state, elapsed_ms, now_ms)
        return state if terminal?(state)

        exp = state[:exp]
        if !state[:skip_only] && elapsed_ms < after_ms(exp)
          state[:last_reason] = "pending: elapsed #{elapsed_ms}ms < after_ms #{after_ms(exp)}ms"
          return state
        end

        status, reason, leaves = yield
        state[:last_reason] = reason.to_s
        state[:skipped_leaves] = leaves || []
        if status == :skip
          state[:skipped] = true
          return state
        end

        if status == :pass
          if state[:held_since].nil?
            state[:held_since] = now_ms
            state[:hit_at] = elapsed_ms
          end
          hold_for = (exp['must_hold_for_ms'] || 0).to_i
          if hold_for <= 0 || (now_ms - state[:held_since]) >= hold_for
            state[:passed] = true
            state[:passed_at] = elapsed_ms
          end
        else
          state[:held_since] = nil
        end
        state[:failed] = true if !state[:passed] && elapsed_ms > exp['within_ms'].to_i
        state
      end

      # One-line outcome for the run log. A PASS names when the hold started
      # (hit) and when it completed, so an anchored row is visibly anchored.
      def describe(state)
        exp = state[:exp]
        label = "exp[#{state[:idx]}] after=#{after_ms(exp)}ms within=#{exp['within_ms']}ms " \
                "hold=#{exp['must_hold_for_ms'] || 0}ms: #{exp['assert']}"
        if state[:skipped]
          "SKIP  #{label} — #{state[:last_reason]}"
        elsif state[:passed]
          partial = (state[:skipped_leaves] || []).map { |leaf| " [SKIPPED leaf: #{leaf}]" }.join
          "PASS  #{label} (hit at #{state[:hit_at]}ms, passed at #{state[:passed_at]}ms)#{partial}"
        else
          "FAIL  #{label} — last: #{state[:last_reason]}"
        end
      end
    end
  end
end
