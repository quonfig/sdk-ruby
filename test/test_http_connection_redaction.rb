# frozen_string_literal: true

require 'test_helper'

# D4 (qfg-9p4i.17): a transport error must not carry URL userinfo, since the
# init error and init log lines are built from it.
class TestHttpConnectionRedaction < Minitest::Test
  def test_wall_clock_timeout_message_has_no_userinfo
    conn = Quonfig::HttpConnection.new('http://alice:hunter2@127.0.0.1:1', 'KEY', timeout_ms: 10)
    err = assert_raises(Faraday::TimeoutError) do
      conn.send(:with_wall_clock_deadline) { sleep 2 }
    end
    refute_includes err.message, 'hunter2'
    refute_includes err.message, 'alice'
    assert_includes err.message, '127.0.0.1:1'
  end
end
