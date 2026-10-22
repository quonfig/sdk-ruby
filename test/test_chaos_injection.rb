# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../chaos/injection'

# qfg-6vno.6: a chaos step the rig cannot apply must fail the run. It used to
# print "no-op" and carry on, so a scenario whose fault never happened could
# still pass every expectation.
class TestChaosInjection < Minitest::Test
  class FakeToxiproxy
    attr_reader :calls

    def initialize
      @calls = []
    end

    def add_toxic(*args)
      @calls << [:add_toxic, *args]
    end

    def set_enabled(*args)
      @calls << [:set_enabled, *args]
    end

    def remove_toxic(*args)
      @calls << [:remove_toxic, *args]
    end
  end

  def test_known_inject_is_applied
    tp = FakeToxiproxy.new
    st = chaos_apply_inject(tp, { 'name' => 'stall', 'sse_silent_stall_after_ms' => 0 })

    assert_equal({ 'proxy' => 'sse', 'toxic' => 'stall' }, st)
    assert_equal [[:add_toxic, 'sse', 'stall', 'timeout', 'downstream', { 'timeout' => 0 }]], tp.calls
  end

  def test_unknown_inject_shape_raises
    tp = FakeToxiproxy.new
    err = assert_raises(ChaosUnsupportedStep) do
      chaos_apply_inject(tp, { 'name' => 'mystery', 'sse_gremlins' => 3 })
    end
    assert_match(/sse_gremlins/, err.message)
    assert_empty tp.calls
  end

  # toxiproxy is TCP-only: an HTTP status cannot be injected. That used to be
  # a printed no-op, which let 08's 401 scenario "run" with no 401 at all.
  def test_http_status_injects_raise
    tp = FakeToxiproxy.new
    assert_raises(ChaosUnsupportedStep) { chaos_apply_inject(tp, { 'name' => 'a', 'sse_http_status' => 401 }) }
    assert_raises(ChaosUnsupportedStep) { chaos_apply_inject(tp, { 'name' => 'b', 'http_status' => 401 }) }
  end

  def test_unknown_process_action_raises
    tp = FakeToxiproxy.new
    err = assert_raises(ChaosUnsupportedStep) do
      chaos_apply_process(tp, { 'action' => 'kill_http_proxy' })
    end
    assert_match(/kill_http_proxy/, err.message)
  end

  def test_unsupported_step_reason_names_the_http_aware_proxy_gap
    assert_match(/HTTP-aware fault proxy/, chaos_unsupported_step_reason([{ 'inject' => { 'sse_http_status' => 401 } }]))
    assert_nil chaos_unsupported_step_reason([{ 'inject' => { 'sse_down_ms' => 10 } }, { 'clear' => 'x' }])
  end
end
