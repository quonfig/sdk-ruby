# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../chaos/scheduler'

# qfg-p35y: scheduled chaos events from one scenario must not fire during
# the next. The scheduler uses a cancellable wait so the ensure block's
# `stop_flag.set!` immediately aborts any pending event.
class TestChaosScheduler < Minitest::Test
  def test_schedule_event_cancelled_when_stop_flag_set_during_wait
    flag = Quonfig::Chaos::StopFlag.new
    fired = false

    t = Quonfig::Chaos.schedule_event(flag, 10_000) { fired = true }

    # Let the worker enter wait(). 50ms is conservative — Thread.new returns
    # immediately, the worker reaches the wait within a few microseconds.
    sleep 0.05
    flag.set!

    # The worker MUST terminate promptly after stop_flag.set!. A bare-sleep
    # implementation would still be napping for the full 10s; join(2.0)
    # would time out and the thread would later fire `block.call` (the leak
    # the fix prevents). Asserting the thread is dead within 2s catches
    # that.
    completed = t.join(2.0)
    refute_nil completed,
               'thread must terminate within 2s of stop_flag.set! — ' \
               'a sleep-based scheduler would still be napping (the qfg-p35y leak)'
    refute fired,
           'scheduled chaos event must NOT fire when stop_flag is set ' \
           'before its delay elapses'
  end

  def test_schedule_event_fires_when_delay_elapses_normally
    flag = Quonfig::Chaos::StopFlag.new
    fired = false

    t = Quonfig::Chaos.schedule_event(flag, 50) { fired = true }
    t.join(2.0)

    assert fired,
           'scheduled chaos event MUST fire when its delay elapses ' \
           'before any stop_flag.set! — happy path is unchanged'
  end

  def test_stop_flag_wait_returns_immediately_when_already_set
    flag = Quonfig::Chaos::StopFlag.new
    flag.set!

    start = Time.now
    flag.wait(5.0)
    elapsed = Time.now - start

    assert elapsed < 0.5,
           'wait() must return immediately when stop_flag is already set ' \
           "(took #{elapsed}s — expected <0.5s)"
  end
end
