# frozen_string_literal: true

# SDK probe for the default chaos suite (chaos/test_chaos.rb). Extracted so it
# can be unit-tested without toxiproxy (test/test_chaos_probe.rb).

class ChaosProbe
  attr_reader :lock, :log_lock

  def initialize
    @lock           = Mutex.new
    @log_lock       = Mutex.new
    @conn_state     = 'initializing' # initializing|connected|reconnecting|falling_back|disconnected
    @client         = nil
    @conn_attempts  = 0
    @restart_layer1 = 0
    @restart_layer2 = 0
    @fallback_active = false
    @process_crashed = false
    @logs = []
  end

  attr_accessor :process_crashed

  # Synthesize a state edge based on the SDK's :connection_state symbol.
  # Mirrors sdk-python's ChaosProbe.on_sse_state semantics:
  #   :connected      -> 'connected', conn_attempts++ ON EDGE ONLY
  #   :falling_back   -> 'falling_back', fallback_active = true
  #   :disconnected   -> 'disconnected'
  #   :initializing   -> 'initializing'
  #
  # qfg-ll6r: @conn_attempts must increment only on the not-connected ->
  # connected EDGE. The poller fires every 50ms; a steady connected state
  # otherwise inflates conn_attempts by ~20/sec and trips chaos scenario 09's
  # `quonfig_sse_connect_attempts_total < 100` guard. (Bug surfaced as a
  # reported 1792 attempts over a 90s window — exactly the poll count.)
  def absorb_sdk_state(sdk_state)
    @lock.synchronize do
      case sdk_state
      when :connected
        @conn_attempts += 1 unless @conn_state == 'connected'
        @conn_state = 'connected'
        # The SDK reports :falling_back exactly while its poll supervisor is
        # alive, so :connected means the fallback poller has stopped. Without
        # this the flag latched true after the first fallback (05 exp[3]).
        @fallback_active = false
      when :falling_back
        # transition into fallback: if we were previously connected, that's a
        # Layer 1 restart edge.
        @restart_layer1 += 1 if @conn_state == 'connected'
        @conn_state = 'falling_back'
        @fallback_active = true
      when :disconnected
        # transition out of connected (but NOT into falling_back) -> reconnecting
        # If we were already disconnected/initializing, stay that way.
        if @conn_state == 'connected'
          @restart_layer1 += 1
          @conn_state = 'reconnecting'
        elsif @conn_state == 'reconnecting'
          # keep reconnecting
        else
          @conn_state = 'disconnected'
        end
        @fallback_active = false
      when :initializing
        # first observation; no edge work
        @conn_state = 'initializing' if @conn_state == 'initializing'
        @fallback_active = false
      end
    end
  end

  # The client whose accessors back the probe. lastSuccessfulRefresh reads
  # client.last_successful_refresh, which every successful poll advances, 304s
  # included (qfg-goi1.10.35). The install-only on_update callback this probe
  # used to stamp from never fires on a 304, so it froze at the t=0 install.
  def client=(c)
    @lock.synchronize { @client = c }
  end

  def last_refresh_ms
    c = @lock.synchronize { @client }
    t = c&.last_successful_refresh
    t ? (t.to_f * 1000).to_i : 0
  end

  def bump_restart_layer1(by = 1)
    @lock.synchronize { @restart_layer1 += by }
  end

  def bump_restart_layer2(by = 1)
    @lock.synchronize { @restart_layer2 += by }
  end

  def log(level, msg)
    line = "level=#{level.to_s.downcase} #{msg}"
    @log_lock.synchronize { @logs << line }
    # Mirror sdk-python/sdk-go: an onConfigUpdate callback throw counts as a
    # Layer 1 restart for chaos scenario 10. Match the user-callback recovery
    # log lines case-insensitively. The current sdk-ruby log line is
    # "onConfigUpdate callback raised" (qfg-47c2.30); historical phrasing
    # ("callback threw", "Error applying SSE envelope") is kept for back-compat
    # with older SDK builds run against this harness.
    return unless msg.to_s =~ /onConfigUpdate callback (raised|threw|panicked)|callback (raised|threw|panicked)|Error applying SSE envelope/i

    @lock.synchronize { @restart_layer1 += 1 }
  end

  def snapshot
    refreshed_ms = last_refresh_ms
    @lock.synchronize do
      {
        conn_state: @conn_state,
        last_refresh_ms: refreshed_ms,
        restart_layer1: @restart_layer1,
        restart_layer2: @restart_layer2,
        fallback_active: @fallback_active,
        process_crashed: @process_crashed
      }
    end
  end

  # Returns the probe's value for an SDK-side metric, or nil for a metric name
  # the probe does not implement, so the evaluator fails the expectation loudly
  # instead of comparing against a silent 0 (qfg-goi1.2.21; sdk-go's `known`).
  def sdk_metric(name, labels)
    @lock.synchronize do
      case name
      when 'quonfig_sdk_worker_restart_total'
        case labels['layer']
        when '1' then @restart_layer1.to_f
        when '2' then @restart_layer2.to_f
        else (@restart_layer1 + @restart_layer2).to_f
        end
      when 'quonfig_sse_connect_attempts_total'
        @conn_attempts.to_f
      end
    end
  end

  def log_matches(level, regex)
    @log_lock.synchronize do
      n = 0
      @logs.each do |line|
        next if level && !level.empty? && !line.downcase.include?("level=#{level.downcase}")

        n += 1 if regex.match?(line)
      end
      n
    end
  end
end
