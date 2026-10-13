# frozen_string_literal: true

require 'test_helper'

# qfg-goi1.2.29 — DatadirWatcher's debounce, driven without a filesystem. A
# fake listen factory captures the change block so the test fires "events"
# directly; no file writes, no FSEvents/inotify latency.
class TestDatadirWatcherDebounce < Minitest::Test
  DEBOUNCE_MS = 100

  class FakeListener
    attr_reader :block

    def initialize(block) = @block = block
    def start; end
    def stop; end
  end

  def setup
    super
    @fires = Concurrent::AtomicFixnum.new(0)
    listeners = @listeners = []
    factory = Class.new do
      define_singleton_method(:to) do |*_args, &blk|
        FakeListener.new(blk).tap { |l| listeners << l }
      end
    end
    watcher_class = Class.new(Quonfig::DatadirWatcher)
    watcher_class.const_set(:LISTEN_FACTORY, factory)
    @watcher = watcher_class.new(datadir: Dir.pwd, debounce_ms: DEBOUNCE_MS,
                                 on_change: -> { @fires.increment }, on_error: ->(e) { raise e })
    assert @watcher.start
  end

  def teardown
    @watcher&.stop
    super
  end

  def fire_event
    @listeners.first.block.call([], [], [])
  end

  def test_events_inside_the_window_coalesce_into_one_trailing_fire
    5.times { fire_event }
    wait_for(-> { @fires.value >= 1 }, max_wait: 5)
    sleep DEBOUNCE_MS * 3 / 1000.0

    assert_equal 1, @fires.value
  end

  def test_an_event_after_the_fire_fires_again
    fire_event
    wait_for(-> { @fires.value == 1 }, max_wait: 5)
    fire_event
    wait_for(-> { @fires.value == 2 }, max_wait: 5)

    assert_equal 2, @fires.value
  end

  def test_stop_cancels_a_pending_fire
    fire_event
    @watcher.stop
    sleep DEBOUNCE_MS * 3 / 1000.0

    assert_equal 0, @fires.value
  end
end
