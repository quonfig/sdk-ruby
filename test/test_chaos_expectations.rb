# frozen_string_literal: true

require 'tmpdir'
require_relative 'test_helper'
require_relative '../chaos/expressions'
require_relative '../chaos/expectations'

# qfg-goi1.10.35 (contract: ITD v2026.10.16.2 chaos/README.md "Timeline
# rules"): an expectation with after_ms is not evaluated, cannot start a hold,
# cannot PASS and is not terminal before after_ms; the loaders reject unknown
# expectation keys, naming the key.
class TestChaosExpectations < Minitest::Test
  E = Quonfig::Chaos::Expectations

  def state(exp)
    E.new_state(0, exp)
  end

  def tick(st, elapsed, status = :pass, reason = 'r')
    calls = 0
    E.step(st, elapsed, 1_000_000 + elapsed) do
      calls += 1
      [status, reason, []]
    end
    calls
  end

  def test_after_ms_true_at_elapsed_zero_is_pending_not_pass
    st = state('assert' => 'x', 'within_ms' => 5000, 'after_ms' => 1000)

    calls = tick(st, 0)

    assert_equal 0, calls, 'assert must not be evaluated before after_ms'
    refute st[:passed], 'PASS before after_ms'
    refute E.terminal?(st)
    assert_nil st[:held_since], 'hold started before after_ms'
  end

  def test_after_ms_passes_once_reached
    st = state('assert' => 'x', 'within_ms' => 5000, 'after_ms' => 1000)
    tick(st, 0)
    tick(st, 999)
    refute st[:passed]

    tick(st, 1000)

    assert st[:passed]
    assert_equal 1000, st[:hit_at]
  end

  def test_after_ms_hold_starts_at_after_ms_and_must_complete
    st = state('assert' => 'x', 'within_ms' => 3000, 'after_ms' => 1000, 'must_hold_for_ms' => 1500)
    tick(st, 500)
    tick(st, 1000)
    assert_equal 1000, st[:hit_at]
    tick(st, 2000)
    refute st[:passed]
    tick(st, 2500)

    assert st[:passed]
  end

  def test_false_sample_resets_hold_and_fails_past_within
    st = state('assert' => 'x', 'within_ms' => 3000, 'after_ms' => 1000, 'must_hold_for_ms' => 1500)
    tick(st, 1000)
    tick(st, 2000, :fail)
    assert_nil st[:held_since]
    tick(st, 2500)
    assert_equal 2500, st[:hit_at]
    tick(st, 3001)

    assert st[:failed]
    refute st[:passed]
  end

  def test_fails_past_within_without_after_ms
    st = state('assert' => 'x', 'within_ms' => 1000)
    tick(st, 1001, :fail)

    assert st[:failed]
  end

  def test_server_metric_with_after_ms_reports_skipped
    expr = "server_metric('quonfig_subscriber_lag_seconds') == 0"
    st = state('assert' => expr, 'within_ms' => 5000, 'after_ms' => 1000)
    st[:skip_only] = Quonfig::Chaos::Expressions.skip_only?(expr)

    E.step(st, 0, 0) do
      r = Quonfig::Chaos::Expressions.evaluate(expr, nil)
      [r.status, r.reason, r.skipped]
    end

    assert st[:skipped]
    refute st[:passed]
    assert_match(/SKIPPED/, st[:last_reason])
  end

  def test_skip_only_is_shape_based
    sm = "server_metric('a') == 0"

    assert Quonfig::Chaos::Expressions.skip_only?(sm)
    assert Quonfig::Chaos::Expressions.skip_only?("#{sm} AND server_metric('b') < 3")
    refute Quonfig::Chaos::Expressions.skip_only?("#{sm} AND client.connectionState() == 'connected'")
    refute Quonfig::Chaos::Expressions.skip_only?("client.connectionState() == 'connected'")
  end

  def write_scenario(dir, exp_yaml)
    path = File.join(dir, 'x.yaml')
    File.write(path, <<~YAML)
      tests:
        - name: unknown key probe
          setup: {}
          chaos: []
          expectations:
      #{exp_yaml}
    YAML
    path
  end

  def test_loader_rejects_unknown_expectation_key_naming_it
    Dir.mktmpdir do |dir|
      path = write_scenario(dir, <<~Y.gsub(/^/, '      '))
        - within_ms: 1000
          not_before_ms: 500
          assert: "client.ready() == true"
      Y

      err = assert_raises(E::UnknownKeyError) { E.load_scenario_file(path) }
      assert_match(/not_before_ms/, err.message)
      assert_match(/exp\[0\]/, err.message)
    end
  end

  def test_loader_accepts_the_four_known_keys
    Dir.mktmpdir do |dir|
      path = write_scenario(dir, <<~Y.gsub(/^/, '      '))
        - within_ms: 1000
          after_ms: 500
          must_hold_for_ms: 100
          assert: "client.ready() == true"
      Y

      doc = E.load_scenario_file(path)
      assert_equal 500, doc['tests'][0]['expectations'][0]['after_ms']
    end
  end
end
