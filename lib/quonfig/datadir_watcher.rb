# frozen_string_literal: true

require 'concurrent'

module Quonfig
  # Watches a datadir for changes and fires +on_change+ once per debounced
  # burst. Wraps the `listen` gem (https://github.com/guard/listen), which
  # uses platform-native backends (FSEvents on macOS, inotify on Linux,
  # polling fallback on Windows).
  #
  # The caller owns parse-then-swap: this class only fires the trigger.
  # Registration failures (read-only fs, immutable container, native backend
  # missing) are surfaced via +on_error+; in that case +start+ returns
  # +false+ and no listener is held.
  #
  # Mirrors sdk-node/src/datadirWatcher.ts (qfg-mol-0kr) modulo Ruby idioms:
  # listen does not have an equivalent to Node's `fs.watch({recursive:true})`,
  # but it watches recursively by default.
  class DatadirWatcher
    # Indirection seam for tests. Production code uses ::Listen; tests can
    # swap in a class that raises from `.to` to exercise the registration-
    # failure path without needing a read-only filesystem.
    LISTEN_FACTORY = nil # resolved lazily so the gem can be required late

    def initialize(datadir:, debounce_ms:, on_change:, on_error:)
      @datadir = datadir
      @debounce_seconds = debounce_ms.to_f / 1000.0
      @on_change = on_change
      @on_error = on_error
      @mutex = Mutex.new
      @scheduled_task = nil
      @listener = nil
      @closed = false
    end

    # Start the underlying file watcher. Returns true on success, false if
    # registration failed (in which case +on_error+ has already been called
    # and the caller should continue without auto-reload).
    #
    # Blocks until the listener is in its :processing_events state (or a
    # short safety timeout elapses) so a customer writing to the datadir
    # immediately after the Client constructor returns is detected, rather
    # than racing the listen backend's async setup.
    def start
      resolved = File.realpath(@datadir)
      factory = self.class::LISTEN_FACTORY || ::Listen
      @listener = factory.to(resolved) do |_modified, _added, _removed|
        schedule_reload
      end
      @listener.start
      wait_for_listener_ready
      true
    rescue StandardError => e
      @on_error.call(e)
      false
    end

    # Stop the watcher and cancel any pending debounce. Idempotent.
    def stop
      task, listener = @mutex.synchronize do
        @closed = true
        t = @scheduled_task
        l = @listener
        @scheduled_task = nil
        @listener = nil
        [t, l]
      end
      begin
        task&.cancel
      rescue StandardError
        # best-effort; caller already in shutdown
      end
      begin
        listener&.stop
      rescue StandardError
        # best-effort
      end
    end

    private

    # Block briefly until the listener reports :processing_events. Listen's
    # state machine supports wait_for_state; we cap at 500 ms so a broken
    # backend cannot wedge the SDK boot. (The native FSEvents backend on
    # macOS still has ~100ms latency *after* this returns — that is a
    # property of the OS, not something we can synchronize away. Tests that
    # need to observe the first post-init write should sleep accordingly.)
    def wait_for_listener_ready
      return unless @listener.respond_to?(:wait_for_state)

      begin
        @listener.wait_for_state(:processing_events, timeout: 0.5)
      rescue StandardError
        # If the FSM doesn't transition, keep going — events may still flow.
      end
    end

    def schedule_reload
      @mutex.synchronize do
        return if @closed

        @scheduled_task&.cancel
        on_change = @on_change
        @scheduled_task = Concurrent::ScheduledTask.execute(@debounce_seconds) do
          # Re-check closed under the mutex so a stop() landing between cancel
          # and execute cannot resurrect a fired callback.
          should_fire = @mutex.synchronize { !@closed }
          on_change.call if should_fire
        end
      end
    end
  end
end
