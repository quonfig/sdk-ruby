# frozen_string_literal: true

require 'test_helper'
require 'json'

# Telemetry transport contract T1-T8 (qfg-y8je.8): the sdk-ruby implementation
# of integration-test-data/chaos/telemetry-transport-contract.md, policy P1-P10
# in project/plans/2026-09-24-sdk-telemetry-transport-policy.md.
#
# Fixture: a real Quonfig::Client (evaluations go through the public #get),
# a real TelemetryReporter + TransportQueue built from the client's Options by
# the same factory Client#initialize_telemetry uses, real HTTP (Faraday) to an
# in-process WEBrick stub. Only the endpoint, the clock and the logger are fake.
#
# Clock: a ManualTelemetryClock drives every telemetry time comparison (the 30s
# floor, Retry-After, batch age, the 10 min WARN cadence). #advance fires the
# reporter's tick at each k * interval boundary it crosses, which is the
# contract's "directly callable tick". The per-POST deadline is enforced by
# Net::HTTP / Timeout on the wall clock, so these tests run with a compressed
# telemetry_timeout_ms and assert the shipped 15000 / 5000 defaults separately
# (the contract's allowance for clients whose timeout cannot run on a mocked
# clock).
class TestTelemetryTransport < Minitest::Test
  MIN = 60_000
  FAST_TIMEOUT_MS = 400
  SDK_KEY = 'qf_sk_test_transport_contract'

  def setup
    super
    @stub = TelemetryStub.new
    @logger = CaptureLogger.new
    @clock = ManualTelemetryClock.new
    @reporters = []
  end

  def teardown
    @reporters.each do |r|
      r.close
    rescue StandardError
      nil
    end
    @stub&.close
    Quonfig::InternalLogger.user_logger = nil
    super
  end

  def config(key)
    rule = { 'criteria' => [{ 'operator' => 'ALWAYS_TRUE' }], 'value' => { 'type' => 'string', 'value' => "v-#{key}" } }
    {
      'id' => "id-#{key}", 'key' => key, 'type' => 'config', 'valueType' => 'string',
      'sendToClientSdk' => false, 'default' => { 'rules' => [rule] }, 'environment' => nil
    }
  end

  def cfg_key(i) = format('cfg-%02d', i % 20)

  # A client whose evaluations feed a real reporter pointed at the stub.
  def build(**overrides)
    store = Quonfig::ConfigStore.new
    20.times { |i| store.set(cfg_key(i), config(cfg_key(i))) }
    options = Quonfig::Options.new(
      sdk_key: SDK_KEY,
      telemetry_url: @stub.url,
      api_urls: ['http://127.0.0.1:1'],
      enable_sse: false,
      fallback_poll_enabled: false,
      enable_quonfig_user_context: false,
      logger: @logger,
      telemetry_timeout_ms: FAST_TIMEOUT_MS,
      **overrides
    )
    @client = Quonfig::Client.new(options, store: store)
    @reporter = Quonfig::Telemetry::TelemetryReporter.build(
      options: options, instance_hash: @client.instance_hash, clock: @clock
    )
    @client.instance_variable_set(:@telemetry_reporter, @reporter)
    @reporters << @reporter
    @interval_ms = (options.collect_sync_interval * 1000).to_i
    @next_tick_at = @clock.now_ms + @interval_ms
    @logger.clear
    @reporter
  end

  # Evaluation set +tag+: three evaluations over configs base..base+2, each with
  # a distinct context key "<tag>-i", so a body identifies its set by the
  # example-context key (and by config key where sets use distinct configs).
  def record(tag, base = 0)
    3.times { |i| @client.get(cfg_key(base + i), nil, 'user' => { 'key' => "#{tag}-#{i}" }) }
  end

  def has?(index, tag) = @stub.body(index).include?("\"#{tag}-0\"")
  def carries_config?(index, key) = @stub.body(index).include?("\"key\":\"#{key}\"")

  # Move the manual clock forward, firing a tick at every interval boundary.
  def advance(ms)
    target = @clock.now_ms + ms
    while @next_tick_at <= target
      @clock.set(@next_tick_at)
      @next_tick_at += @interval_ms
      @reporter.tick
    end
    @clock.set(target)
  end

  def state = @reporter.debug_state
  def logs(level, pattern = /.*/) = @logger.log_count(level, pattern)

  # ---- T1 --------------------------------------------------------------

  def test_t1_timeout_aborts_and_retains
    build
    record('A')
    @stub.script({ hang: true }, { status: 200 })

    advance(MIN) # tick 1: POST 0 hangs and is aborted at the (compressed) deadline
    advance(15_000)
    assert_equal 1, @stub.post_count
    assert_equal 1, state[:retained_count]
    assert_equal 0, logs(:warn)
    assert_equal 0, logs(:error)
    assert_equal 1, logs(:debug, /Telemetry POST failed \(timeout\)/)

    advance(45_000) # tick 2, past the 30s floor
    assert_equal 2, @stub.post_count
    assert_equal @stub.sha(0), @stub.sha(1)
    assert_equal 0, state[:retained_count]
    assert_equal 1, logs(:info, /recover/i)
    assert_equal 0, logs(:warn)
  end

  def test_t1_defaults_timeout_15000_connect_5000_interval_60
    options = Quonfig::Options.new(sdk_key: SDK_KEY, enable_sse: false)
    assert_equal 15_000, options.telemetry_timeout_ms
    assert_equal 5_000, options.telemetry_connect_timeout_ms
    assert_equal 60, options.collect_sync_interval

    reporter = Quonfig::Telemetry::TelemetryReporter.build(options: options, instance_hash: 'h')
    assert_equal 15_000, reporter.config[:timeout_ms]
    assert_equal 5_000, reporter.config[:connect_timeout_ms]
    assert_equal 60_000, reporter.config[:flush_interval_ms]

    # The Faraday connection the reporter POSTs through carries both deadlines.
    faraday = reporter.send(:telemetry_connection, 15_000).connection.options
    assert_equal 5.0, faraday.open_timeout
    assert_equal 15.0, faraday.timeout
  end

  # ---- T2 --------------------------------------------------------------

  def test_t2_5xx_retains_verbatim_and_resends
    build
    record('A', 0)
    @stub.script({ status: 503 }, { status: 503 }, { status: 200 }, { status: 200 })

    advance(MIN)
    assert_equal 1, state[:retained_count]

    record('B', 3)
    advance(MIN)
    assert_equal 2, @stub.post_count
    assert_equal 2, state[:retained_count]

    advance(MIN)
    assert_equal 4, @stub.post_count
    assert_equal @stub.sha(0), @stub.sha(1)
    assert_equal @stub.sha(0), @stub.sha(2)
    assert has?(3, 'B')
    refute has?(3, 'A')
    refute carries_config?(3, 'cfg-00')
    assert carries_config?(3, 'cfg-03')
    assert_equal 0, state[:retained_count]
  end

  # ---- T3 --------------------------------------------------------------

  [401, 403, 404].each do |status|
    define_method("test_t3a_#{status}_disables_telemetry_for_the_process") do
      build
      record('A')
      @stub.script({ status: 503 }, { status: status })
      advance(MIN)
      assert_equal 1, state[:retained_count]

      record('B', 3)
      advance(MIN)
      assert_equal 1, logs(:error, /#{status}/)
      refute state[:enabled]
      assert_equal 0, state[:retained_count]
      assert_equal 0, logs(:warn)

      posts = @stub.post_count
      3.times do |i|
        record("C#{i}", 6)
        advance(MIN)
      end
      assert_equal posts, @stub.post_count
      assert_equal 1, logs(:error)
    end
  end

  [400, 413, 422].each do |status|
    define_method("test_t3b_#{status}_drops_the_batch_and_keeps_ticking") do
      build
      record('A')
      @stub.script({ status: status }, { status: 200 })
      advance(MIN)
      assert_equal 0, state[:retained_count]
      assert_equal 1, logs(:error)
      assert_equal 0, logs(:warn)
      assert state[:enabled]

      record('B', 3)
      advance(MIN)
      assert_equal 2, @stub.post_count
      refute_equal @stub.sha(0), @stub.sha(1)
    end
  end

  def test_t3_408_is_retryable_anti_vacuity
    build
    record('A')
    @stub.script({ status: 408 })
    advance(MIN)
    assert_equal 1, state[:retained_count]
    assert state[:enabled]
  end

  # ---- T4 --------------------------------------------------------------

  def test_t4a_30s_floor_after_a_failure
    build(collect_sync_interval: 8)
    record('A')
    @stub.script({ status: 503 }, { status: 200 })

    advance(8_000) # POST 0 fails at F
    assert_equal 1, @stub.post_count
    3.times do # F+8s, F+16s, F+24s
      advance(8_000)
      assert_equal 1, @stub.post_count
    end
    advance(8_000) # F+32s: the first tick at or after F+30s
    assert_equal 2, @stub.post_count
    assert_equal @stub.sha(0), @stub.sha(1)
  end

  def test_t4b_retry_after_delta_seconds_honored
    build
    record('A')
    @stub.script({ status: 429, retry_after: '120' }, { status: 200 })

    advance(MIN) # F
    advance(MIN) # F+60
    assert_equal 1, @stub.post_count
    advance(59_000) # F+119
    assert_equal 1, @stub.post_count
    advance(1_000) # F+120: the tick at F+120s sends
    assert_equal 2, @stub.post_count
    assert_equal @stub.sha(0), @stub.sha(1)
  end

  def test_t4b_retry_after_http_date_honored
    build
    record('A')
    @stub.script({ status: 503, retry_after: (Time.now + 120).httpdate }, { status: 200 })

    advance(MIN)
    advance(MIN)
    assert_equal 1, @stub.post_count
    advance(MIN)
    assert_equal 2, @stub.post_count
    assert_equal @stub.sha(0), @stub.sha(1)
  end

  def test_t4c_retry_after_clamped_to_600s_and_aged_batch_discarded
    build
    record('A')
    @stub.script({ status: 503, retry_after: '3600' }, { status: 200 })

    advance(MIN) # F
    record('B', 3)
    advance(9 * MIN) # F+540
    advance(59_000) # F+599
    assert_equal 1, @stub.post_count
    advance(1_000) # F+600
    assert_equal 2, @stub.post_count
    assert has?(1, 'B')
    refute has?(1, 'A')
    assert_equal 1, logs(:warn)
  end

  # ---- T5 --------------------------------------------------------------

  def test_t5_queue_caps_evict_oldest_and_resend_oldest_first
    build
    @stub.default = { status: 503 }
    first_sha = {}
    (1..8).each do |k|
      record("E#{k}", k)
      advance(MIN)
      first_sha[k] = @stub.sha(@stub.post_count - 1) if has?(@stub.post_count - 1, "E#{k}")
      assert_operator state[:retained_count], :<=, 5
      assert_operator state[:retained_bytes], :<=, 2_097_152
    end
    assert_equal 5, state[:retained_count]

    before = @stub.post_count
    @stub.default = { status: 200 }
    advance(MIN)
    assert_equal before + 5, @stub.post_count
    (4..8).each_with_index do |k, i|
      index = before + i
      assert has?(index, "E#{k}"), "POST #{index} should carry E#{k}"
      assert_equal first_sha[k], @stub.sha(index) if first_sha[k]
    end
    (before...@stub.post_count).each { |i| refute has?(i, 'E1') }
  end

  def test_t5_max_age_discards_batches_older_than_5_min
    build
    @stub.default = { status: 503 }
    (1..3).each do |k|
      record("E#{k}", k)
      advance(MIN)
    end
    advance(6 * MIN)
    assert_equal 0, state[:retained_count]

    before = @stub.post_count
    @stub.default = { status: 200 }
    advance(MIN)
    assert_equal before, @stub.post_count, 'nothing left to send'
  end

  def test_t5_oversize_batch_is_posted_once_then_dropped
    build(telemetry_max_retained_bytes: 4096)
    40.times { |i| @client.get(cfg_key(i), nil, 'user' => { 'key' => "big-#{i}", 'pad' => 'x' * 64 }) }
    @stub.script({ status: 503 })

    advance(MIN)
    assert_equal 1, @stub.post_count
    assert_operator @stub.body(0).bytesize, :>, 4096
    assert_equal 0, state[:retained_count]
    assert_equal 0, state[:retained_bytes]
    assert_equal 1, logs(:warn)
    assert_equal 1, logs(:warn, /larger than the byte cap/)

    advance(MIN)
    assert_equal 1, @stub.post_count, 'the oversize batch is never resent'
  end

  def test_t5_shipped_queue_defaults
    options = Quonfig::Options.new(sdk_key: SDK_KEY, enable_sse: false)
    assert_equal 5, options.telemetry_max_retained_batches
    assert_equal 2_097_152, options.telemetry_max_retained_bytes
    assert_equal 300_000, options.telemetry_max_retained_age_ms
  end

  def test_t5_aggregator_caps_drop_newest_and_existing_keys_keep_counting
    build(collect_max_evaluation_summaries: 3, context_max_size: 3)
    # Six distinct configs, six distinct contexts with one field each.
    6.times { |i| @client.get(cfg_key(i), nil, 'user' => { 'key' => "cap-#{i}" }) }
    # An already-present summary key after the cap is reached still counts.
    @client.get(cfg_key(0), nil, 'user' => { 'key' => 'cap-0' })
    # New shape fields beyond the cap are not recorded.
    @client.get(cfg_key(0), nil, 'user' => { 'key' => 'cap-0', 'a' => 1, 'b' => 2, 'c' => 3 })

    advance(MIN)
    payload = JSON.parse(@stub.body(0))
    summaries = payload['events'].find { |e| e['summaries'] }['summaries']['summaries']
    assert_equal(%w[cfg-00 cfg-01 cfg-02], summaries.map { |s| s['key'] }.sort)
    cfg0 = summaries.find { |s| s['key'] == 'cfg-00' }
    assert_equal(3, cfg0['counters'].sum { |c| c['count'] })

    examples = payload['events'].find { |e| e['exampleContexts'] }['exampleContexts']['examples']
    assert_equal 3, examples.size

    shapes = payload['events'].find { |e| e['contextShapes'] }['contextShapes']['shapes']
    assert_equal(3, shapes.sum { |s| s['fieldTypes'].size })
  end

  def test_t5_shipped_aggregator_cap_defaults
    options = Quonfig::Options.new(sdk_key: SDK_KEY, enable_sse: false)
    assert_equal 10_000, options.collect_max_evaluation_summaries
    assert_equal 10_000, options.collect_max_shapes
    assert_equal 10_000, options.collect_max_example_contexts
    assert_equal 100_000, Quonfig::Telemetry::ExampleContextsAggregator::SEEN_CAP
  end

  def test_t5_example_context_rate_limit_map_is_bounded
    agg = Quonfig::Telemetry::ExampleContextsAggregator.new(max_contexts: 10, seen_cap: 5)
    8.times { |i| agg.record(Quonfig::Context.new('user' => { 'key' => "k#{i}" })) }
    assert_equal 5, agg.cache.data.size
    assert_equal 5, agg.data.size
  end

  # ---- T6 --------------------------------------------------------------

  def test_t6a_blip_no_warn_one_recovery_info
    build
    record('A')
    @stub.script({ status: 503 }, { status: 200 })
    advance(MIN)
    advance(MIN)
    assert_equal 2, @stub.post_count
    assert_equal 0, logs(:warn)
    assert_equal 1, logs(:info, /recover/i)
    assert_operator logs(:debug), :>=, 1
    assert_equal 0, logs(:error)
  end

  def test_t6b_sustained_failure_one_warn_then_recovery_info
    build
    @stub.default = { status: 503 }
    (1..5).each do |k|
      record("E#{k}", k)
      advance(MIN)
    end
    assert_equal 0, logs(:warn)

    record('E6', 6)
    advance(MIN) # tick 6: first eviction
    assert_equal 1, logs(:warn)
    warn = @logger.lines(:warn).first.last
    assert_match(/last POST result: 503/, warn)
    assert_match(%r{retained queue 5/5 batches}, warn)
    assert_match(/1 batch\(es\) dropped so far/, warn)

    (7..9).each do |k|
      record("E#{k}", k)
      advance(MIN)
    end
    assert_equal 1, logs(:warn)

    @stub.default = { status: 200 }
    advance(MIN)
    assert_equal 1, logs(:info, /recover/i)
    assert_equal 0, logs(:error)
  end

  def test_t6c_warn_summary_at_most_once_per_10_min
    build
    @stub.default = { status: 503 }
    (1..6).each do |k|
      record("E#{k}", k)
      advance(MIN)
    end
    assert_equal 1, logs(:warn) # first drop at tick 6

    (7..15).each do |k|
      record("E#{k}", k)
      advance(MIN)
    end
    assert_equal 1, logs(:warn)

    record('E16', 16)
    advance(MIN) # tick 16: 10 min after the first WARN
    assert_equal 2, logs(:warn)
    assert_match(/Telemetry still dropping data: 10 batch\(es\) dropped in the last 10 min/,
                 @logger.lines(:warn).last.last)

    (17..24).each do |k|
      record("E#{k}", k)
      advance(MIN)
    end
    assert_equal 2, logs(:warn)
    assert_equal 0, logs(:error)
  end

  # ---- T7 --------------------------------------------------------------

  def test_t7_one_post_in_flight_skipped_windows_aggregate
    build(telemetry_timeout_ms: 5_000)
    record('A', 0)
    @stub.script({ hang: true })

    first = Thread.new { @reporter.tick }
    @stub.wait_for_posts(1)
    assert state[:in_flight]

    record('B', 3)
    @reporter.tick
    record('C', 6)
    @reporter.tick
    assert_equal 1, @stub.post_count

    @stub.release(0, { status: 200 })
    first.join(5)

    @reporter.tick
    assert_equal 2, @stub.post_count
    assert has?(1, 'B')
    assert has?(1, 'C')
    refute has?(1, 'A')
  end

  # ---- T8 --------------------------------------------------------------

  def test_t8_close_final_flush_does_not_drain_and_never_blocks
    build
    @reporter.start # a real reporter thread (first real tick in 60s) that close() must stop
    assert state[:thread_alive]

    @stub.default = { status: 503 }
    record('A', 0)
    advance(@interval_ms)
    record('B', 3)
    advance(@interval_ms)
    assert_equal 2, state[:retained_count]
    retained = [@stub.sha(0), @stub.sha(1)]
    posts = @stub.post_count

    record('C', 6)
    @stub.default = { hang: true }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @reporter.close
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    @stub.wait_for_posts(posts + 1)

    assert_operator elapsed, :<, (FAST_TIMEOUT_MS / 1000.0) + 1.0
    assert_equal posts + 1, @stub.post_count, 'exactly one final-flush POST'
    refute_includes retained, @stub.sha(posts)
    assert has?(posts, 'C')

    advance(10 * @interval_ms)
    assert_equal posts + 1, @stub.post_count, 'no POST after close'
    refute state[:thread_alive]
    @reporter.close # second close is a no-op
    assert_equal posts + 1, @stub.post_count
  end

  # ---- The real reporter thread (the tests above call the tick directly) ----

  def test_reporter_thread_ticks_on_a_fixed_interval_that_never_grows
    build(collect_sync_interval: 0.05)
    assert_equal([50, 50, 50], Array.new(3) { @reporter.send(:next_interval_ms) })

    @reporter.start
    3.times do |i|
      record("R#{i}", i)
      @stub.wait_for_posts(i + 1)
    end
    assert_equal 0, logs(:warn)
  end

  def test_t8_shutdown_deadline_is_5s
    assert_equal 5_000, Quonfig::Telemetry::TransportQueue::SHUTDOWN_FLUSH_DEADLINE_MS
  end
end
