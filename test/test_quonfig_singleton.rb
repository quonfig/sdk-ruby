# frozen_string_literal: true

require 'test_helper'

# Quonfig.init (module-level singleton). qfg-goi1.2.11: the "already
# initialized?" check sat outside the write lock, so two threads calling
# init at once could each build a Client; one was orphaned with a live SSE
# stream and telemetry thread nothing would stop.
class TestQuonfigSingleton < Minitest::Test
  def setup
    super
    Quonfig.instance_variable_set(:@singleton, nil)
  end

  def teardown
    Quonfig.instance_variable_set(:@singleton, nil)
    super
  end

  def test_concurrent_init_builds_exactly_one_client
    constructions = Concurrent::AtomicFixnum.new(0)
    fake_client = Object.new
    slow_new = lambda do |*_args|
      constructions.increment
      sleep 0.05
      fake_client
    end

    results = []
    Quonfig::LOG.stub(:warn, ->(*_args, &_) {}) do
      Quonfig::Client.stub(:new, slow_new) do
        threads = Array.new(2) { Thread.new { Quonfig.init } }
        results = threads.map(&:value)
      end
    end

    assert_equal 1, constructions.value, 'Quonfig.init must construct exactly one Client under a race'
    assert(results.all? { |c| c.equal?(fake_client) }, 'both callers must get the same singleton')
    assert_same fake_client, Quonfig.instance
  end

  def test_second_init_returns_existing_and_warns
    fake_client = Object.new
    warns = []
    Quonfig::LOG.stub(:warn, ->(msg = nil, &_) { warns << msg }) do
      Quonfig::Client.stub(:new, ->(*_args) { fake_client }) do
        assert_same fake_client, Quonfig.init
        assert_same fake_client, Quonfig.init
      end
    end
    assert_equal ['Quonfig already initialized.'], warns
  end
end
