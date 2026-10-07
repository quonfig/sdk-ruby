# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../chaos/expressions'

# qfg-goi1.1.3: `server_metric(...)` must evaluate to an explicit SKIPPED with
# a reason, never a silent 0 that passes. In compound expressions the skipped
# leaf is neutral: the other leaves are still enforced.
class TestChaosExpressions < Minitest::Test
  LAG = "server_metric('quonfig_subscriber_lag_seconds') == 0"

  class FakeProbe
    def initialize(conn_state)
      @conn_state = conn_state
    end

    def snapshot
      { conn_state: @conn_state, fallback_active: false, process_crashed: false, last_refresh_ms: 0 }
    end

    def sdk_metric(_name, _labels)
      0.0
    end

    def log_matches(_level, _regex)
      0
    end
  end

  def eval_expr(expr, conn_state = 'connected')
    Quonfig::Chaos::Expressions.evaluate(expr, FakeProbe.new(conn_state))
  end

  def test_server_metric_alone_is_skipped_with_reason
    r = eval_expr(LAG)

    assert_equal :skip, r.status
    assert_match(/SKIPPED/, r.reason)
    assert_match(/OTLP/, r.reason)
    assert_match(/qfg-47c2\.19/, r.reason)
    assert_match(/QuonfigSubscriberLagHigh/, r.reason)
    assert_equal 1, r.skipped.size
    assert_match(/quonfig_subscriber_lag_seconds/, r.skipped.first)
  end

  def test_server_metric_is_skipped_whatever_the_comparison
    # A silent 0 would pass `== 0` and fail `> 0`; a skip is independent of both.
    assert_equal :skip, eval_expr("server_metric('quonfig_subscriber_lag_seconds') > 5").status
  end

  def test_and_with_skipped_leaf_passes_when_other_leaves_pass
    r = eval_expr("client.connectionState() == 'connected' AND #{LAG}", 'connected')

    assert_equal :pass, r.status
    assert_equal 1, r.skipped.size
  end

  def test_and_with_skipped_leaf_still_enforces_other_leaves
    r = eval_expr("client.connectionState() == 'connected' AND #{LAG}", 'falling_back')

    assert_equal :fail, r.status
    assert_match(/connectionState=falling_back/, r.reason)
  end

  def test_or_skipped_leaf_does_not_satisfy_the_or
    r = eval_expr("#{LAG} OR client.connectionState() == 'connected'", 'falling_back')

    assert_equal :fail, r.status
  end

  def test_or_passes_on_a_real_leaf
    r = eval_expr("#{LAG} OR client.connectionState() == 'connected'", 'connected')

    assert_equal :pass, r.status
  end

  def test_compound_of_only_skipped_leaves_is_skipped
    assert_equal :skip, eval_expr("#{LAG} AND #{LAG}").status
  end

  def test_plain_leaves_pass_and_fail
    assert_equal :pass, eval_expr("client.connectionState() == 'connected'", 'connected').status
    assert_equal :fail, eval_expr("client.connectionState() == 'connected'", 'disconnected').status
    assert_empty eval_expr("client.connectionState() == 'connected'", 'connected').skipped
  end

  def test_unrecognized_expression_fails
    r = eval_expr('client.somethingNew() == 1')

    assert_equal :fail, r.status
    assert_match(/unrecognized expression/, r.reason)
  end

  # qfg-goi1.2.21: a probe answers nil from #sdk_metric for a metric name it
  # does not implement (sdk-go's `known == false`). The evaluator must fail
  # that expectation loudly instead of comparing against a silent 0, which
  # would make `client.sdkMetric('typo_total') == 0` pass without checking.
  class MetricProbe < FakeProbe
    def initialize(metrics)
      super('connected')
      @metrics = metrics
    end

    def sdk_metric(name, _labels)
      @metrics[name]
    end
  end

  def eval_metric(expr, metrics = { 'quonfig_sse_connect_attempts_total' => 0.0 })
    Quonfig::Chaos::Expressions.evaluate(expr, MetricProbe.new(metrics))
  end

  def test_unknown_sdk_metric_fails_loudly
    r = eval_metric("client.sdkMetric('typo_total') == 0")

    assert_equal :fail, r.status
    assert_match(/unknown sdkMetric "typo_total": the chaos probe does not implement it/, r.reason)
  end

  def test_unknown_sdk_metric_fails_whatever_the_comparison
    # A silent 0 would pass `< 5` and fail `> 0`; unknown fails both.
    assert_equal :fail, eval_metric("client.sdkMetric('typo_total', layer='1') < 5").status
    assert_equal :fail, eval_metric("client.sdkMetric('typo_total') > 0").status
  end

  def test_unknown_sdk_metric_fails_inside_an_and
    r = eval_metric("client.connectionState() == 'connected' AND client.sdkMetric('typo_total') == 0")

    assert_equal :fail, r.status
    assert_match(/unknown sdkMetric "typo_total"/, r.reason)
  end

  def test_known_sdk_metric_still_compares
    assert_equal :pass, eval_metric("client.sdkMetric('quonfig_sse_connect_attempts_total') == 0").status
    assert_equal :fail, eval_metric("client.sdkMetric('quonfig_sse_connect_attempts_total') > 0").status
  end
end
