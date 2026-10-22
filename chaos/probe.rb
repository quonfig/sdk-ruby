# frozen_string_literal: true

# SDK probe for the default chaos suite (chaos/test_chaos.rb). Extracted so it
# can be unit-tested without toxiproxy (test/test_chaos_probe.rb).
#
# Every value an expectation reads comes from the SDK itself, read live at
# evaluation time (qfg-6vno.6): Client#connection_state, the per-layer
# Client#worker_restart_total counters, Client#last_successful_refresh,
# Client#ready?, Client#get_string, the SDK's log lines (via
# Quonfig::InternalLogger.user_logger) and its on_update callback. The probe
# keeps no state machine or counters of its own, so it can never report a
# value the supervisor contract forbids (such as 'reconnecting') or a restart
# the SDK did not count.
#
# Two reads go through private Client helpers, the same ones
# Client#connection_state is built from. They are internal, read only by this
# chaos harness:
#   - sse_channel_expected?  (is this client supposed to hold an SSE stream)
#   - sse_worker_alive?      (is the SSE worker thread running)

class ChaosProbe
  INIT_STATES = %w[pending returned raised].freeze

  attr_reader :log_lock

  def initialize
    @lock = Mutex.new
    @log_lock = Mutex.new
    @client = nil
    # 'returned' unless the runner drives init on its own thread (00-*).
    @init_state = 'returned'
    @ready_events = 0
    # Set when Client.new raised and the runner has no client at all.
    @process_crashed = false
    @logs = []
  end

  def client=(c)
    @lock.synchronize { @client = c }
  end

  def client
    @lock.synchronize { @client }
  end

  def process_crashed=(v)
    @lock.synchronize { @process_crashed = v }
  end

  def init_state=(s)
    raise ArgumentError, "init_state must be one of #{INIT_STATES.join('|')}, got #{s.inspect}" unless INIT_STATES.include?(s)

    @lock.synchronize { @init_state = s }
  end

  def init_state
    @lock.synchronize { @init_state }
  end

  # Called from the on_update callback the runner registers once the init call
  # has returned: one per ready/update event the SDK fires.
  def note_ready_event
    @lock.synchronize { @ready_events += 1 }
  end

  def ready_event_count
    @lock.synchronize { @ready_events }
  end

  # Before the client exists (init still pending on its own thread) the SDK is
  # initializing; there is no other state it could be in.
  def connection_state
    c = client
    c ? c.connection_state.to_s : 'initializing'
  end

  def ready?
    c = client
    c ? c.ready? == true : false
  end

  # The SDK's public string getter with the caller's default. With no client
  # the caller gets its default, as any getter would before init returns.
  def get_string(key, default)
    c = client
    return default if c.nil?

    c.get_string(key, default: default)
  end

  def last_refresh_ms
    t = client&.last_successful_refresh
    t ? (t.to_f * 1000).to_i : 0
  end

  # processStillAlive(): the SDK did not crash. Ruby has no process-level
  # crash for a background raise, so this is "Client.new did not blow up and,
  # if the client is supposed to stream, its SSE worker thread is running".
  def process_alive?
    return false if @lock.synchronize { @process_crashed }

    c = client
    return false if c.nil?
    return true unless c.send(:sse_channel_expected?)

    c.send(:sse_worker_alive?) == true
  end

  def log(level, msg)
    line = "level=#{level.to_s.downcase} #{msg}"
    @log_lock.synchronize { @logs << line }
  end

  def snapshot
    {
      conn_state: connection_state,
      last_refresh_ms: last_refresh_ms,
      restart_layer1: sdk_metric('quonfig_sdk_worker_restart_total', { 'layer' => '1' }),
      restart_layer2: sdk_metric('quonfig_sdk_worker_restart_total', { 'layer' => '2' }),
      fallback_active: connection_state == 'falling_back',
      process_crashed: !process_alive?
    }
  end

  # Returns the SDK's value for an SDK-side metric, or nil when the probe has
  # no SDK source for it (unknown name, or no client yet), so the evaluator
  # fails the expectation loudly instead of comparing a silent 0
  # (qfg-goi1.2.21; sdk-go's `known`).
  #
  # quonfig_sse_connect_attempts_total: SSEConfigClient dials once, then once
  # per reconnect, and bumps restart_total (Client#worker_restart_total
  # layer '1') before every reconnect dial. So dials = 1 + restart_total for a
  # client that streams, 0 for one that does not.
  def sdk_metric(name, labels)
    c = client
    return nil if c.nil?

    case name
    when 'quonfig_sdk_worker_restart_total'
      layer = labels['layer']
      (layer ? c.worker_restart_total(layer: layer) : c.worker_restart_total).to_f
    when 'quonfig_sse_connect_attempts_total'
      dials = c.send(:sse_channel_expected?) ? 1 + c.worker_restart_total(layer: '1') : 0
      dials.to_f
    when 'quonfig_sdk_callback_errors_total'
      # Client#callback_errors_total (qfg-6vno.6.1, contract Test 5).
      callback = labels['callback']
      (callback ? c.callback_errors_total(callback: callback) : c.callback_errors_total).to_f
    end
  end

  # Lines at exactly +level+ (when given) that match +regex+.
  def log_matches(level, regex)
    @log_lock.synchronize do
      n = 0
      @logs.each do |line|
        next if level && !level.empty? && !line.start_with?("level=#{level.downcase} ")

        n += 1 if regex.match?(line)
      end
      n
    end
  end
end
