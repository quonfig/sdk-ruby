# frozen_string_literal: true

# Expression evaluator for the cross-SDK chaos harness (qfg-47c2.25).
#
# Extracted from chaos/test_chaos.rb so the expression vocabulary can be
# unit-tested without booting toxiproxy or api-delivery (see
# test/test_chaos_expressions.rb). A +probe+ is any object answering
# #snapshot, #sdk_metric(name, labels) and #log_matches(level, regex).

module Quonfig
  module Chaos
    module Expressions
      module_function

      # Why server_metric(...) is not evaluated by this rig (Decision 6 in
      # project/sdk-quality-check/META-ANALYSIS.md): api-delivery exports its
      # metrics only by OTLP push, so there is nothing to scrape from here.
      SERVER_METRIC_SKIP_REASON =
        'server-side metric; api-delivery exports via OTLP only, no scrape endpoint ' \
        'in the rig; covered by staging drill qfg-47c2.19 and the QuonfigSubscriberLagHigh alert'

      Result = Struct.new(:status, :reason, :skipped) do
        def pass?
          status == :pass
        end
      end

      RE_CONN_STATE_EQ = /\Aclient\.connectionState\(\)\s*(==|!=)\s*'([^']+)'\z/
      RE_FALLBACK_EQ   = /\Aclient\.fallbackPollerActive\(\)\s*==\s*(true|false)\z/
      RE_PROC_ALIVE_EQ = /\Aclient\.processStillAlive\(\)\s*==\s*(true|false)\z/
      RE_LAST_REFRESH  = /\Aclient\.lastSuccessfulRefresh\(\)\s*(>=|>|<=|<|==)\s*\(now\(\)\s*-\s*(\d+)\)\z/
      RE_SDK_METRIC    = /\Aclient\.sdkMetric\(\s*'([^']+)'\s*(?:,\s*layer=\s*'([^']+)'\s*)?\)\s*(>=|<=|==|!=|<|>)\s*(\d+)\z/
      RE_SERVER_METRIC = /\Aserver_metric\(\s*'([^']+)'\s*\)\s*(>=|<=|==|!=|<|>)\s*(\d+)\z/
      RE_SDK_LOG       = %r{\Aclient\.sdkLog\(\s*'([^']+)'\s*,\s*/(.+)/i\s*\)\s*(>=|<=|==|!=|<|>)\s*(\d+)\z}

      def split_outside_quotes(expr, sep)
        out = []
        in_sq = false
        in_re = false
        start = 0
        i = 0
        while i < expr.length
          c = expr[i]
          if c == "'" && !in_re
            in_sq = !in_sq
          elsif c == '/' && !in_sq
            in_re = !in_re
          end
          if !in_sq && !in_re && expr[i, sep.length] == sep
            out << expr[start...i]
            start = i + sep.length
            i += sep.length
            next
          end
          i += 1
        end
        out << expr[start..]
        out
      end

      def compare(op, a, b)
        case op
        when '==' then a == b
        when '!=' then a != b
        when '<'  then a < b
        when '<=' then a <= b
        when '>'  then a > b
        when '>=' then a >= b
        else false
        end
      end

      def eval_leaf(expr, probe)
        expr = expr.strip
        if (m = RE_CONN_STATE_EQ.match(expr))
          op = m[1]
          want = m[2]
          snap = probe.snapshot
          got = snap[:conn_state]
          ok = op == '==' ? got == want : got != want
          return [ok, "connectionState=#{got} #{op} #{want}"]
        end
        if (m = RE_FALLBACK_EQ.match(expr))
          want = m[1] == 'true'
          got = probe.snapshot[:fallback_active]
          return [got == want, "fallbackPollerActive=#{got} want #{want}"]
        end
        if (m = RE_PROC_ALIVE_EQ.match(expr))
          want = m[1] == 'true'
          alive = !probe.snapshot[:process_crashed]
          return [alive == want, "processStillAlive=#{alive} want #{want}"]
        end
        if (m = RE_LAST_REFRESH.match(expr))
          op  = m[1]
          ago = m[2].to_i
          last = probe.snapshot[:last_refresh_ms]
          threshold = (Time.now.to_f * 1000).to_i - ago
          ok = compare(op, last, threshold)
          return [ok, "lastSuccessfulRefresh=#{last} #{op} (now()-#{ago})=#{threshold}"]
        end
        if (m = RE_SDK_METRIC.match(expr))
          metric = m[1]
          layer = m[2]
          op = m[3]
          want = m[4].to_f
          labels = layer ? { 'layer' => layer } : {}
          got = probe.sdk_metric(metric, labels)
          ok = compare(op, got, want)
          return [ok, "sdkMetric(#{metric},layer=#{layer || ''})=#{got} #{op} #{want}"]
        end
        if (m = RE_SERVER_METRIC.match(expr))
          # Explicit SKIP, never a silent 0 (qfg-goi1.1.3, Decision 6).
          return [:skip, "server_metric(#{m[1]}) #{m[2]} #{m[3]}: #{SERVER_METRIC_SKIP_REASON}"]
        end

        if (m = RE_SDK_LOG.match(expr))
          level = m[1]
          pattern = m[2]
          op = m[3]
          want = m[4].to_f
          regex = Regexp.new(pattern, Regexp::IGNORECASE)
          got = probe.log_matches(level, regex).to_f
          ok = compare(op, got, want)
          return [ok, "sdkLog(#{level},/#{pattern}/i)=#{got} #{op} #{want}"]
        end
        [false, "unrecognized expression: #{expr}"]
      end

      # Evaluate +expr+ against +probe+. Returns a Result whose +status+ is
      # :pass, :fail or :skip. A skipped leaf is neutral in a compound: an AND
      # passes when every non-skipped leaf passes, an OR passes only when a
      # non-skipped leaf passes, and a compound whose leaves are all skipped is
      # itself skipped. +skipped+ lists every skipped leaf with its reason.
      def evaluate(expr, probe)
        expr = expr.to_s.strip
        return Result.new(:pass, '', []) if expr.empty?

        return combine(:or, split_outside_quotes(expr, ' OR ').map { |p| evaluate(p, probe) }) if expr.include?(' OR ')
        return combine(:and, split_outside_quotes(expr, ' AND ').map { |p| evaluate(p, probe) }) if expr.include?(' AND ')

        ok, why = eval_leaf(expr, probe)
        return Result.new(:skip, "SKIPPED #{why}", [why]) if ok == :skip

        Result.new(ok ? :pass : :fail, why, [])
      end

      def combine(kind, results)
        skipped = results.flat_map(&:skipped)
        live = results.reject { |r| r.status == :skip }
        return Result.new(:skip, "SKIPPED #{skipped.join(' | ')}", skipped) if live.empty?

        label = kind == :or ? 'OR' : 'AND'
        ok = kind == :or ? live.any?(&:pass?) : live.all?(&:pass?)
        return Result.new(:pass, '', skipped) if ok

        reasons = kind == :or ? live.map(&:reason) : [live.find { |r| !r.pass? }.reason]
        Result.new(:fail, "#{label}: #{reasons.join(' | ')}", skipped)
      end
    end
  end
end
