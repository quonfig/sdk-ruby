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

      def eval_leaf(expr, probe, server_metric)
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
          name = m[1]
          op = m[2]
          want = m[3].to_f
          got = server_metric.call(name)
          ok = compare(op, got, want)
          return [ok, "server_metric(#{name})=#{got} #{op} #{want}"]
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

      def evaluate(expr, probe, server_metric)
        expr = expr.to_s.strip
        return [true, ''] if expr.empty?

        if expr.include?(' OR ')
          parts = split_outside_quotes(expr, ' OR ')
          reasons = []
          parts.each do |p|
            ok, why = evaluate(p, probe, server_metric)
            return [true, ''] if ok

            reasons << why
          end
          return [false, "OR: #{reasons.join(' | ')}"]
        end
        if expr.include?(' AND ')
          parts = split_outside_quotes(expr, ' AND ')
          parts.each do |p|
            ok, why = evaluate(p, probe, server_metric)
            return [false, "AND: #{why}"] unless ok
          end
          return [true, '']
        end
        eval_leaf(expr, probe, server_metric)
      end
    end
  end
end
