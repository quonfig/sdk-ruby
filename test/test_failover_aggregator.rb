# frozen_string_literal: true

require 'test_helper'

# Unit tests for the failover-telemetry aggregator (qfg-41nh.18). Mirrors
# sdk-go's internal/telemetry/failover_aggregator_test.go: thread-safe additive
# counters over a flush window, a wire event only when at least one counter is
# non-zero, and camelCase field names matching api-telemetry's Zod schema.
class TestFailoverAggregator < Minitest::Test
  def test_empty_returns_nil
    agg = Quonfig::Telemetry::FailoverAggregator.new
    assert_nil agg.drain_event, 'a healthy client with no failover activity emits nothing'
  end

  def test_counts_and_clears_with_camelcase_wire_shape
    agg = Quonfig::Telemetry::FailoverAggregator.new
    agg.record_hedge_fired
    agg.record_hedge_fired
    agg.record_guard_rejected
    agg.record_resolved_from(0) # primary
    agg.record_resolved_from(1) # secondary
    agg.record_resolved_from(2) # secondary (any index > 0)

    event = agg.drain_event
    refute_nil event, 'expected a failover event once counters are non-zero'
    assert event.key?('failover'), "event must be keyed by 'failover'"

    f = event['failover']
    # EXACT camelCase field names — api-telemetry's Zod schema + ClickHouse MV
    # parse these keys.
    assert_equal 2, f['hedgeFired']
    assert_equal 1, f['guardRejected']
    assert_equal 1, f['resolvedFromPrimary']
    assert_equal 2, f['resolvedFromSecondary']
    assert_equal 0, f['resolvedFromLkg']

    assert_kind_of Integer, f['start']
    assert_kind_of Integer, f['end']
    assert_operator f['start'], :>, 0
    assert_operator f['end'], :>=, f['start']

    # After draining, the window resets: a subsequent empty window is nil.
    assert_nil agg.drain_event, 'aggregator must reset after drain'
  end

  def test_negative_or_nil_source_index_ignored
    agg = Quonfig::Telemetry::FailoverAggregator.new
    # SSE / datadir installs carry no HTTP leg — a nil/negative source index must
    # not count as a resolved-from and must not, by itself, produce an event.
    agg.record_resolved_from(nil)
    agg.record_resolved_from(-1)
    assert_nil agg.drain_event, 'a no-leg install must not produce a failover event'
  end

  # The window start must be stamped at the FIRST record, and end at drain time
  # — not both at drain. Guards the window semantics (a memoization refactor
  # once silently repointed the start stamp to the wrong ivar).
  def test_window_start_is_first_record_end_is_drain
    agg = Quonfig::Telemetry::FailoverAggregator.new
    t1 = Time.utc(2026, 7, 6, 12, 0, 0)
    t2 = Time.utc(2026, 7, 6, 12, 0, 5)

    Timecop.freeze(t1) { agg.record_guard_rejected }
    event = Timecop.freeze(t2) { agg.drain_event }

    f = event['failover']
    assert_equal t1.to_i * 1000, f['start'], 'start must be stamped at the first record'
    assert_equal t2.to_i * 1000, f['end'], 'end must be stamped at drain time'
  end

  def test_only_resolved_from_primary_still_emits
    agg = Quonfig::Telemetry::FailoverAggregator.new
    agg.record_resolved_from(0)

    event = agg.drain_event
    refute_nil event
    f = event['failover']
    assert_equal 1, f['resolvedFromPrimary']
    assert_equal 0, f['resolvedFromSecondary']
    assert_equal 0, f['hedgeFired']
    assert_equal 0, f['guardRejected']
  end
end
