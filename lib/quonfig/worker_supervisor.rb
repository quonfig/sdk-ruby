# frozen_string_literal: true

module Quonfig
  # Internal control-flow exception raised inside a supervised worker thread
  # to signal cooperative shutdown. Workers may catch and re-raise, or just
  # propagate.
  class Shutdown < StandardError; end

  # Single supervisor for a long-lived background worker (SSE read loop,
  # fallback poller). Catches unhandled exceptions at the worker boundary,
  # logs them, increments +worker_restart_total+, and restarts with
  # exponential backoff capped at 30s.
  #
  # Contract: integration-test-data/chaos/supervisor-test-contract.md
  # Plan:     project/plans/sdk-hardening-and-verification.md (Phase 1)
  #
  # The worker is a Proc-like callable invoked as +worker.call(notify_delivered)+
  # where +notify_delivered+ is a Proc the worker calls when it has handed at
  # least one envelope to the cache. That signal resets the backoff so a
  # transient blip doesn't double the delay on the next disconnect.
  #
  # Shutdown is signaled by Thread#raise(Quonfig::Shutdown) into the
  # supervisor thread. Logger writes and bookkeeping use Thread.handle_interrupt
  # so a concurrent raise doesn't trip Ruby's "log writing failed" path.
  class WorkerSupervisor
    METRIC_NAME = 'quonfig_sdk_worker_restart_total'

    DEFAULT_INITIAL_BACKOFF = 0.5
    DEFAULT_MAX_BACKOFF     = 30.0
    DEFAULT_MULTIPLIER      = 2.0
    SHUTDOWN_TIMEOUT_SEC    = 5.0

    LOG = Quonfig::InternalLogger.new(self)

    attr_reader :worker_restart_total, :worker_restart_labels

    def initialize(name:, worker:, layer: '1',
                   initial_backoff: DEFAULT_INITIAL_BACKOFF,
                   max_backoff: DEFAULT_MAX_BACKOFF,
                   multiplier: DEFAULT_MULTIPLIER,
                   sleep_proc: nil,
                   logger: nil)
      @name = name
      @layer = layer.to_s
      @worker = worker
      @initial_backoff = initial_backoff
      @max_backoff = max_backoff
      @multiplier = multiplier
      @sleep_proc = sleep_proc || ->(seconds) { sleep(seconds) }
      @logger = logger || LOG
      @worker_restart_total = 0
      @worker_restart_labels = {
        sdk: 'ruby',
        sdk_version: Quonfig::VERSION,
        layer: @layer
      }.freeze
      @mutex = Mutex.new
      @stop_requested = false
      @thread = nil
      @current_backoff = @initial_backoff
    end

    def start
      @mutex.synchronize do
        return self if @thread&.alive?

        @stop_requested = false
        @thread = Thread.new { run_loop }
      end
      self
    end

    def alive?
      t = @thread
      !t.nil? && t.alive?
    end

    def stop
      thread = @mutex.synchronize do
        @stop_requested = true
        t = @thread
        @thread = nil
        t
      end
      return if thread.nil?

      raise_shutdown(thread)
      thread.join(SHUTDOWN_TIMEOUT_SEC)
      thread.kill if thread.alive?
      nil
    end

    alias close stop

    private

    def raise_shutdown(thread)
      return if thread.nil?
      return unless thread.alive?

      begin
        thread.raise(Quonfig::Shutdown.new('supervisor stopping'))
      rescue ThreadError
        # thread already exited between alive? and raise — fine
      end
    end

    def run_loop
      Thread.current.name = "quonfig-supervisor-#{@name}"
      # Don't dump our managed Shutdown to stderr on shutdown.
      Thread.current.report_on_exception = false

      loop do
        break if stop?

        delivered = false
        notify_delivered = -> { delivered = true }
        reason = :worker_exit

        begin
          @worker.call(notify_delivered)
        rescue Quonfig::Shutdown
          break
        rescue StandardError => e
          reason = :worker_throw
          safe_log(:error,
                   "[quonfig] supervisor=#{@name} worker raised #{e.class}: #{e.message}")
          bt = e.backtrace&.first(10)&.join("\n")
          safe_log(:debug, bt) if bt
        end

        break if stop?

        @worker_restart_total += 1
        @current_backoff = @initial_backoff if delivered
        backoff = @current_backoff

        safe_log(:warn,
                 "[quonfig] supervisor=#{@name} restarting worker " \
                 "(reason=#{reason}, restart_total=#{@worker_restart_total}, " \
                 "backoff_s=#{backoff})")

        begin
          @sleep_proc.call(backoff)
        rescue Quonfig::Shutdown
          break
        end

        @current_backoff = [@current_backoff * @multiplier, @max_backoff].min
      end
    rescue Quonfig::Shutdown
      # supervisor-level cooperative shutdown
    rescue StandardError => e
      safe_log(:error, "[quonfig] supervisor=#{@name} crashed: #{e.class}: #{e.message}")
    end

    def stop?
      @mutex.synchronize { @stop_requested }
    end

    # Defer Shutdown delivery while we're inside Logger.write so we don't
    # trip Logger's "log writing failed" -> stderr fallback. Swallow any
    # other logger error.
    def safe_log(level, msg)
      return unless @logger.respond_to?(level)

      Thread.handle_interrupt(Quonfig::Shutdown => :never) do
        @logger.public_send(level, msg)
      end
    rescue StandardError
      nil
    end
  end
end
