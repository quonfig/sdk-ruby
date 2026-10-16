# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../chaos/probe'

# qfg-goi1.10.35: the default-suite probe's lastSuccessfulRefresh must track
# the SDK accessor (client.last_successful_refresh), which every successful
# poll advances, 304s included. The install-only on_update callback never
# fires on a 304, so a probe stamped from it freezes at the t=0 install and
# chaos 05 exp[2] goes red for a probe reason.
class TestChaosProbe < Minitest::Test
  class FakeClient
    attr_accessor :last_successful_refresh

    def initialize
      @callbacks = []
    end

    def on_update(&blk)
      @callbacks << blk
    end

    def install!(at)
      @last_successful_refresh = at
      @callbacks.each(&:call)
    end

    # A 304 / same-generation poll: freshness advances, no install callback.
    def not_modified!(at)
      @last_successful_refresh = at
    end
  end

  def test_freshness_moves_after_a_304_only_refresh
    client = FakeClient.new
    probe = ChaosProbe.new
    probe.client = client

    client.install!(Time.at(1_700_000_000).utc)
    later = Time.at(1_700_000_100).utc
    client.not_modified!(later)

    assert_equal (later.to_f * 1000).to_i, probe.snapshot[:last_refresh_ms]
  end

  def test_freshness_is_zero_before_first_install
    probe = ChaosProbe.new
    assert_equal 0, probe.snapshot[:last_refresh_ms]

    probe.client = FakeClient.new
    assert_equal 0, probe.snapshot[:last_refresh_ms]
  end
end
